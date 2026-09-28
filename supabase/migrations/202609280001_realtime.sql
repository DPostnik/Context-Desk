-- Event-driven remote protocol v2. Apply after 202609270001_remote.sql.
-- Full v1 snapshots remain readable; v2 transports changed chats only.
begin;
alter table public.remote_devices add column revision bigint not null default 0;
create table public.remote_chat_changes (
    device uuid not null references public.remote_devices(id) on delete cascade,
    chat text not null,
    revision bigint not null,
    payload jsonb,
    primary key (device, chat)
);
alter table public.remote_chat_changes enable row level security;
create policy remote_chat_owner on public.remote_chat_changes for select to authenticated
using (exists(select 1 from public.remote_devices d where d.id = device and d.owner = auth.uid()));
grant select on public.remote_chat_changes to authenticated;
revoke all on public.remote_chat_changes from anon;

-- Revision increments and changed-chat records are atomic with the snapshot.
create function public.remote_snapshot_revision() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    if tg_op = 'INSERT' then new.revision := 1;
    elsif new.snapshot is distinct from old.snapshot then new.revision := old.revision + 1;
    else new.revision := old.revision;
    end if;
    return new;
end $$;
create trigger remote_snapshot_revision before insert or update on public.remote_devices
for each row execute function public.remote_snapshot_revision();

create function public.remote_snapshot_signal() returns trigger
language plpgsql security definer set search_path = '' as $$
declare d public.remote_devices;
begin
    if tg_op = 'DELETE' then d := old; else d := new; end if;
    if tg_op <> 'DELETE' then
        if tg_op = 'UPDATE' and new.revision = old.revision then return new; end if;
        insert into public.remote_chat_changes(device, chat, revision, payload)
        select new.id, c->>'id', new.revision, c from jsonb_array_elements(new.snapshot->'chats') c
        on conflict (device, chat) do update set revision = excluded.revision, payload = excluded.payload
        where remote_chat_changes.payload is distinct from excluded.payload;
        update public.remote_chat_changes set payload = null, revision = new.revision
        where device = new.id and payload is not null
          and not exists(select 1 from jsonb_array_elements(new.snapshot->'chats') c where c->>'id' = chat);
    end if;
    perform realtime.send(jsonb_build_object('entity','device','device',d.id),
                          'changed', 'remote:' || d.owner::text, true);
    return d;
end $$;
create trigger remote_snapshot_signal after insert or update or delete on public.remote_devices
for each row execute function public.remote_snapshot_signal();

create function public.remote_command_signal() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.remote_commands;
begin
    if tg_op = 'DELETE' then c := old; else c := new; end if;
    perform realtime.send(jsonb_build_object('entity','command','device',c.device,'id',c.id,'status',c.status),
                          'changed', 'remote:' || c.owner::text, true);
    return c;
end $$;
create trigger remote_command_signal after insert or update or delete on public.remote_commands
for each row execute function public.remote_command_signal();

-- Clients can receive only their own notifications; only Presence may be sent.
create policy remote_events_read on realtime.messages for select to authenticated
using (realtime.topic() = 'remote:' || (select auth.uid())::text
       and extension in ('broadcast', 'presence'));
create policy remote_presence_write on realtime.messages for insert to authenticated
with check (realtime.topic() = 'remote:' || (select auth.uid())::text and extension = 'presence');

-- Atomic patch upload. Lock the device to serialize revisions; do not upload
-- unchanged chats. The resulting snapshot retains compatibility with v1 readers.
create function public.patch_remote_snapshot(device_id uuid, device_name text, project_list jsonb,
                                             chat_order text[], changed_chats jsonb) returns void
language plpgsql security invoker set search_path = '' as $$
declare previous jsonb; document jsonb;
begin
    if auth.uid() is null or jsonb_array_length(changed_chats) > 20 or cardinality(chat_order) > 20 then
        raise exception 'invalid snapshot';
    end if;
    select snapshot into previous from public.remote_devices where id = device_id for update;
    select jsonb_build_object('version',1,'projects',project_list,'chats',coalesce(jsonb_agg(c.payload order by ids.ord),'[]'::jsonb))
    into document from unnest(chat_order) with ordinality ids(id,ord)
    cross join lateral (
        select payload from (
            select value as payload, 0 as priority from jsonb_array_elements(changed_chats) where value->>'id' = ids.id
            union all
            select value, 1 from jsonb_array_elements(coalesce(previous->'chats','[]'::jsonb)) where value->>'id' = ids.id
        ) matches order by priority limit 1
    ) c;
    insert into public.remote_devices(id,owner,name,projects,snapshot)
    values(device_id,auth.uid(),device_name,array(select value->>'id' from jsonb_array_elements(project_list)),document)
    on conflict(id) do update set name = excluded.name, projects = excluded.projects,
        snapshot = excluded.snapshot, seen = now();
end $$;

create function public.read_remote_changes(device_id uuid, since_revision bigint) returns jsonb
language sql stable security invoker set search_path = '' as $$
    select jsonb_build_object('device', to_jsonb(d) || jsonb_build_object('snapshot', d.snapshot || '{"chats":[]}'::jsonb),
        'chats', coalesce((select jsonb_agg(c.payload) from public.remote_chat_changes c
                          where c.device = d.id and c.revision > since_revision and c.payload is not null),'[]'::jsonb),
        'order', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(d.snapshot->'chats') c),'[]'::jsonb))
    from public.remote_devices d where d.id = device_id;
$$;
create function public.remote_protocol_version() returns integer language sql stable as $$ select 2 $$;
revoke all on function public.patch_remote_snapshot(uuid,text,jsonb,text[],jsonb),
    public.read_remote_changes(uuid,bigint), public.remote_protocol_version() from public;
grant execute on function public.patch_remote_snapshot(uuid,text,jsonb,text[],jsonb),
    public.read_remote_changes(uuid,bigint), public.remote_protocol_version() to authenticated;
revoke all on function public.remote_snapshot_revision(), public.remote_snapshot_signal(), public.remote_command_signal() from public;

-- Seed delta reads for snapshots created by the preview before this migration.
insert into public.remote_chat_changes(device,chat,revision,payload)
select d.id,c->>'id',0,c from public.remote_devices d cross join lateral jsonb_array_elements(d.snapshot->'chats') c;
commit;
