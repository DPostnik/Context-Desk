-- Remote protocol v1. Apply once to the explicitly selected Supabase project.
-- Authenticated clients use a public key and their own Auth session, never service_role.
begin;
create table public.remote_devices (
    id uuid primary key,
    owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
    name text not null check (length(name) <= 200),
    seen timestamptz not null default now(),
    projects text[] not null default '{}',
    snapshot jsonb not null check (octet_length(snapshot::text) <= 1048576),
    unique(id, owner)
);
create table public.remote_commands (
    id uuid primary key,
    owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
    device uuid not null,
    project text not null,
    chat text not null check (length(chat) between 1 and 500),
    kind text not null check (kind in ('send','stop','allow','deny')),
    text text not null default '' check (octet_length(text) <= 32000),
    approval uuid,
    turn text,
    status text not null default 'pending' check (status in ('pending','claimed','submitted','stop_requested','rejected','uncertain')),
    created timestamptz not null default now(),
    foreign key (device, owner) references public.remote_devices(id, owner) on delete cascade,
    check (kind not in ('allow','deny') or approval is not null)
);
create index remote_commands_queue on public.remote_commands(device, created) where status = 'pending';
alter table public.remote_devices enable row level security;
alter table public.remote_commands enable row level security;
create policy devices_owner on public.remote_devices for all to authenticated
    using (owner = (select auth.uid())) with check (owner = (select auth.uid()));
create policy commands_read on public.remote_commands for select to authenticated using (owner = (select auth.uid()));
create policy commands_insert on public.remote_commands for insert to authenticated with check (
    owner = (select auth.uid()) and status = 'pending'
    and exists(select 1 from public.remote_devices d where d.id = device and d.owner = auth.uid() and project = any(d.projects))
);
create policy commands_update on public.remote_commands for update to authenticated
    using (owner = (select auth.uid())) with check (owner = (select auth.uid()));
create policy commands_delete on public.remote_commands for delete to authenticated using (owner = (select auth.uid()));
-- Freeze command identity/payload. No transition from a claimed or terminal state back to pending.
create function public.guard_remote_command() returns trigger language plpgsql set search_path = '' as $$
begin
    if (to_jsonb(new) - 'status') is distinct from (to_jsonb(old) - 'status') then
        raise exception 'immutable command';
    end if;
    if not ((old.status = 'pending' and new.status = 'claimed') or
            (old.status = 'claimed' and new.status in ('submitted','stop_requested','rejected','uncertain'))) then
        raise exception 'invalid command transition';
    end if;
    return new;
end $$;
create trigger remote_command_guard before update on public.remote_commands for each row execute function public.guard_remote_command();
create function public.claim_remote_command(device_id uuid) returns setof public.remote_commands
language sql security invoker set search_path = '' as $$
    update public.remote_commands set status = 'claimed'
    where id = (select id from public.remote_commands
                where device = device_id and owner = auth.uid() and status = 'pending'
                  and (kind <> 'send' or not exists (
                      select 1 from public.remote_commands earlier
                      where earlier.device = remote_commands.device and earlier.chat = remote_commands.chat
                        and earlier.status in ('claimed', 'uncertain')
                  ))
                order by case when kind = 'send' then 1 else 0 end, created, id
                for update skip locked limit 1)
    returning *;
$$;
revoke all on public.remote_devices, public.remote_commands from anon;
grant select, insert, update, delete on public.remote_devices, public.remote_commands to authenticated;
revoke all on function public.claim_remote_command(uuid) from public;
grant execute on function public.claim_remote_command(uuid) to authenticated;
commit;
