-- Apply after photos. Only image payloads expire; command identity/history stay intact.
begin;
alter table public.remote_commands add column photos_expire_at timestamptz;
-- Existing terminal payloads receive a full grace period, never an immediate purge.
-- Temporarily remove only the immutable-payload trigger inside this transaction.
drop trigger remote_command_guard on public.remote_commands;
update public.remote_commands set photos_expire_at = now() + interval '1 hour'
where photos is not null and status in ('submitted','rejected','uncertain');
create or replace function public.guard_remote_command() returns trigger language plpgsql set search_path = '' as $$
begin
    if old.photos is not null and new.photos is null
       and old.status in ('submitted','rejected','uncertain')
       and old.photos_expire_at <= now()
       and (to_jsonb(new) - 'photos') is not distinct from (to_jsonb(old) - 'photos') then
        return new;
    end if;
    if (to_jsonb(new) - 'status') is distinct from (to_jsonb(old) - 'status') then
        raise exception 'immutable command';
    end if;
    if not ((old.status = 'pending' and new.status = 'claimed') or
            (old.status = 'claimed' and new.status in ('submitted','stop_requested','rejected','uncertain'))) then
        raise exception 'invalid command transition';
    end if;
    if new.photos is not null and new.status in ('submitted','rejected','uncertain') then
        new.photos_expire_at := now() + interval '1 hour';
    end if;
    return new;
end $$;
create trigger remote_command_guard before update on public.remote_commands
for each row execute function public.guard_remote_command();
create index remote_photos_expiry on public.remote_commands(photos_expire_at)
where photos is not null and status in ('submitted','rejected','uncertain');
-- Invoker security: maintenance role can sweep all owners; clients cannot invoke this function.
create function public.cleanup_remote_photos() returns bigint
language plpgsql security invoker set search_path = '' as $$
declare cleaned bigint;
begin
    update public.remote_commands set photos = null
    where id in (select id from public.remote_commands
                 where photos is not null and photos_expire_at <= now()
                   and status in ('submitted','rejected','uncertain')
                 order by photos_expire_at, id for update skip locked limit 500);
    get diagnostics cleaned = row_count;
    return cleaned;
end $$;
revoke all on function public.cleanup_remote_photos() from public, anon, authenticated;
comment on column public.remote_commands.photos is 'Temporary JPEG payload. Cleared one hour after terminal receipt by scheduled maintenance; pending/claimed payloads remain available for delivery.';
notify pgrst, 'reload schema';
commit;
