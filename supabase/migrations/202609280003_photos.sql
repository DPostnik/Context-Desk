-- Small JPEG attachments travel atomically with the immutable command under existing owner RLS.
begin;
create function public.valid_remote_photos(value jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
declare photo jsonb; bytes bytea;
begin
    if value is null then return true; end if;
    if jsonb_typeof(value) <> 'array' then return false; end if;
    if jsonb_array_length(value) > 4 or octet_length(value::text) > 2900000 then return false; end if;
    for photo in select jsonb_array_elements(value) loop
        if jsonb_typeof(photo) <> 'object' or photo->>'id' is null or photo->>'data' is null then return false; end if;
        perform (photo->>'id')::uuid;
        bytes := decode(photo->>'data', 'base64');
        if octet_length(bytes) not between 4 and 524288 or substring(bytes from 1 for 3) <> decode('ffd8ff', 'hex') then return false; end if;
    end loop;
    return true;
exception when others then return false;
end $$;
alter table public.remote_commands add column photos jsonb;
alter table public.remote_commands add constraint remote_photos_valid check (
    public.valid_remote_photos(photos) and (photos is null or kind = 'send')
);
comment on column public.remote_commands.photos is 'Up to four JPEGs, 512 KiB each; private owner-scoped command data. Retained until device cloud copy is deleted.';
notify pgrst, 'reload schema';
commit;
