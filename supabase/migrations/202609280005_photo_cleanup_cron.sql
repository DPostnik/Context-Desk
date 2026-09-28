-- Supabase-hosted activation; run after photo_retention. Named schedule is idempotent.
begin;
create extension if not exists pg_cron;
select cron.schedule('context-desk-photo-cleanup', '*/5 * * * *',
                     'select public.cleanup_remote_photos();');
commit;
