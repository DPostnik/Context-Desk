-- Explicit settings actions fail closed on older hosts. Existing clients remain compatible.
begin;
create function public.valid_remote_options(value jsonb) returns boolean
language sql immutable set search_path = '' as $$
    select coalesce(jsonb_typeof(value) = 'object'
        and jsonb_typeof(value->'model') = 'string'
        and octet_length(value->>'model') between 1 and 200
        and (value - 'model' - 'access') = '{}'::jsonb
        and (not (value ? 'access') or value->'access' = 'null'::jsonb or value->>'access' in ('standard','fullAccess')), false);
$$;
create function public.valid_remote_settings(value jsonb, action text) returns boolean
language sql immutable set search_path = '' as $$
    select case when action in ('create','configure') then coalesce(
        jsonb_typeof(value) = 'object' and octet_length(value::text) <= 4000
        and (value - 'options' - 'expected' - 'expectedProjectAccess') = '{}'::jsonb
        and public.valid_remote_options(value->'options')
        and case when action = 'configure' then
            public.valid_remote_options(value->'expected') and value->>'expectedProjectAccess' in ('standard','fullAccess')
        else (value->'expected' is null or value->'expected' = 'null'::jsonb)
            and (value->'expectedProjectAccess' is null or value->'expectedProjectAccess' = 'null'::jsonb) end, false)
    else value is null end;
$$;
alter table public.remote_commands add column settings jsonb;
alter table public.remote_commands drop constraint remote_commands_kind_check;
alter table public.remote_commands add constraint remote_commands_kind_check check (kind in ('send','stop','allow','deny','create','configure'));
alter table public.remote_commands drop constraint remote_photos_valid;
alter table public.remote_commands add constraint remote_photos_valid check (
    public.valid_remote_photos(photos) and (photos is null or kind in ('send','create'))
);
alter table public.remote_commands add constraint remote_settings_valid check (
    public.valid_remote_settings(settings, kind)
    and (kind not in ('create','configure') or (approval is null and turn is null))
    and (kind <> 'create' or (chat = 'mobile:' || id::text and (length(trim(text)) > 0 or coalesce(jsonb_array_length(photos),0) > 0)))
    and (kind <> 'configure' or (text = '' and photos is null))
);
create or replace function public.claim_remote_command(device_id uuid) returns setof public.remote_commands
language sql security invoker set search_path = '' as $$
    update public.remote_commands set status = 'claimed'
    where id = (select id from public.remote_commands
                where device = device_id and owner = auth.uid() and status = 'pending'
                  and (kind not in ('send','create','configure') or not exists (
                      select 1 from public.remote_commands earlier
                      where earlier.device = remote_commands.device and earlier.chat = remote_commands.chat
                        and earlier.status in ('claimed', 'uncertain')
                  ))
                order by case when kind in ('send','create','configure') then 1 else 0 end, created, id
                for update skip locked limit 1)
    returning *;
$$;
create function public.remote_settings_version() returns integer
language sql stable security invoker set search_path = '' as $$ select 1; $$;
revoke all on function public.remote_settings_version() from public;
grant execute on function public.remote_settings_version() to authenticated;
notify pgrst, 'reload schema';
commit;
