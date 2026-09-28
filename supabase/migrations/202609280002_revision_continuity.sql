-- Keep revisions monotonic even after Delete cloud copy -> enable again.
-- A phone can receive coalesced delete/create events for the same Mac ID.
begin;
lock table public.remote_devices in share row exclusive mode;
create sequence public.remote_snapshot_revisions;
select setval('public.remote_snapshot_revisions', greatest(coalesce(max(revision),0),1), coalesce(max(revision),0) > 0)
from public.remote_devices;
revoke all on sequence public.remote_snapshot_revisions from public, anon, authenticated;
create or replace function public.remote_snapshot_revision() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    if tg_op = 'INSERT' then new.revision := nextval('public.remote_snapshot_revisions');
    elsif new.snapshot is distinct from old.snapshot then new.revision := nextval('public.remote_snapshot_revisions');
    else new.revision := old.revision;
    end if;
    return new;
end $$;
commit;
