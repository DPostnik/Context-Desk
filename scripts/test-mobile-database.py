#!/usr/bin/env python3
"""Exercise the Supabase migration in an isolated local PostgreSQL cluster (no app data)."""
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
bindir = Path(os.environ.get('CONTEXTDESK_POSTGRES_BIN', '/opt/homebrew/opt/postgresql@17/bin'))
if not (bindir/'initdb').exists():
    raise SystemExit('Set CONTEXTDESK_POSTGRES_BIN to a PostgreSQL bin directory.')
with tempfile.TemporaryDirectory(prefix='context-remote-db-', dir='/tmp') as directory:
    folder = Path(directory)
    def run(name, *args, **kwargs):
        result = subprocess.run([str(bindir/name), *map(str,args)], capture_output=True, text=True, **kwargs)
        if result.returncode: raise subprocess.CalledProcessError(result.returncode, result.args, result.stdout, result.stderr)
        return result
    try: run('initdb', '-D', folder/'data', '-A', 'trust', '--no-locale', '--encoding=UTF8', env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    except subprocess.CalledProcessError as error: raise SystemExit(error.stderr)
    started = False
    try:
        run('pg_ctl', '-D', folder/'data', '-l', folder/'postgres.log', '-o', f"-k {folder} -h '' -p 55439", '-w', 'start')
        started = True
        def sql(text):
            return run('psql','-h',folder,'-p','55439','-d','postgres','-v','ON_ERROR_STOP=1','-At',input=text).stdout.strip()
        sql('''create role anon; create role authenticated;
            create schema auth; create table auth.users(id uuid primary key);
            create function auth.uid() returns uuid language sql stable as
            $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
            grant usage on schema auth to authenticated;
            grant execute on function auth.uid() to authenticated;
            insert into auth.users values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');''')
        sql((root/'supabase/migrations/202609270001_remote.sql').read_text())
        # Only the Realtime transport is stubbed. PostgreSQL transactions, triggers,
        # security invoker/definer functions and RLS are exercised by the real engine.
        sql("""create schema realtime;
            create table realtime.messages(topic text, event text, extension text, payload jsonb, private boolean);
            alter table realtime.messages enable row level security;
            grant usage on schema realtime to authenticated;
            grant select, insert on realtime.messages to authenticated;
            create function realtime.topic() returns text language sql stable as
                $$ select current_setting('realtime.topic',true) $$;
            create function realtime.send(payload jsonb,event text,topic text,private boolean) returns void
                language sql security definer set search_path = '' as $$
                insert into realtime.messages values(topic,event,'broadcast',payload,private) $$;""")
        sql((root/'supabase/migrations/202609280001_realtime.sql').read_text())
        sql((root/'supabase/migrations/202609280002_revision_continuity.sql').read_text())
        sql((root/'supabase/migrations/202609280003_photos.sql').read_text())
        assert sql("select public.valid_remote_photos(null), public.valid_remote_photos('[]'), public.valid_remote_photos('{}'), public.valid_remote_photos('[{\"id\":\"bad\",\"data\":\"/9j/AA==\"}]');") == 't|t|f|f'

        owner = "set role authenticated; set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';"
        other = "set role authenticated; set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';"
        device = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        command = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        sql(owner + f"insert into public.remote_devices(id,name,projects,snapshot) values ('{device}','Mac',array['project'],'{{}}');")
        assert sql(other + 'select count(*) from public.remote_devices;').endswith('0')
        insert = f"insert into public.remote_commands(id,device,project,chat,kind,text) values ('{command}','{device}','project','chat','send','hello');"
        def rejects(text):
            try: sql(text)
            except subprocess.CalledProcessError: return
            raise AssertionError('Expected database rejection')
        rejects(other + insert)
        rejects(owner + insert.replace("'project'", "'wrong-project'"))
        sql(owner + insert)
        rejects(owner + insert)
        rejects(owner + "update public.remote_commands set photos = '[]';")
        assert sql("select public.valid_remote_photos('[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"data\":\"/9j/AA==\"}]');") == 't'
        assert sql("select public.valid_remote_photos(jsonb_build_array(jsonb_build_object('id','11111111-1111-1111-1111-111111111111','data',encode(repeat('x',524289)::bytea,'base64'))));") == 'f'
        assert sql(owner + f"select status from public.claim_remote_command('{device}');").endswith('claimed')
        assert sql(owner + f"select count(*) from public.claim_remote_command('{device}');").endswith('0')
        rejects(owner + "update public.remote_commands set text = 'changed';")
        rejects(owner + "update public.remote_commands set status = 'pending';")
        assert sql(other + 'select count(*) from public.remote_commands;').endswith('0')
        sql(owner + "update public.remote_commands set status = 'uncertain';")
        rejects(owner + "update public.remote_commands set status = 'claimed';")
        sql(owner + 'delete from public.remote_devices;')
        assert sql(owner + 'select count(*) from public.remote_commands;').endswith('0')
        import json
        patch = f"select public.patch_remote_snapshot('{device}','Mac','[{{\"id\":\"project\",\"name\":\"Project\"}}]',array['a','b'],'[{{\"id\":\"a\",\"text\":\"first\"}},{{\"id\":\"b\",\"text\":\"second\"}}]');"
        sql(owner + patch)
        rev = int(sql(owner + 'select revision from public.remote_devices;').splitlines()[-1])
        def delta(since, who=owner):
            result = sql(who + f"select public.read_remote_changes('{device}',{since});").splitlines()[-1]
            return json.loads(result) if result.startswith('{') else None
        initial = delta(-1)
        assert len(initial['chats']) == 2 and initial['order'] == ['a','b']
        assert initial['device']['snapshot']['chats'] == []
        assert delta(-1, other) is None
        before = int(sql('select count(*) from realtime.messages;').splitlines()[-1])
        sql(owner + patch)
        assert int(sql('select count(*) from realtime.messages;').splitlines()[-1]) == before
        sql(owner + patch.replace('first','changed'))
        update = delta(rev)
        assert update['chats'] == [{'id':'a','text':'changed'}]
        changed_revision = update['device']['revision']
        assert changed_revision > rev
        sql(owner + f"select public.patch_remote_snapshot('{device}','Mac','[]',array['b'],'[]');")
        assert delta(changed_revision)['order'] == ['b']
        assert delta(changed_revision)['chats'] == []
        rejects(other + patch)
        rejects("set role anon; select public.remote_protocol_version();")
        # Signals contain only routing identifiers, never transcript/command text.
        signals = json.loads(sql("select jsonb_agg(payload) from realtime.messages;").splitlines()[-1])
        assert all(set(e) <= {'entity','device','id','status'} for e in signals)
        before = sql('select count(*) from realtime.messages;').splitlines()[-1]
        sql('begin;' + owner + patch + 'rollback;')
        assert sql('select count(*) from realtime.messages;').splitlines()[-1] == before
        owner_topic = "set realtime.topic = 'remote:11111111-1111-1111-1111-111111111111';"
        assert not sql(owner + owner_topic + 'select count(*) from realtime.messages;').endswith('0')
        assert sql(other + owner_topic + 'select count(*) from realtime.messages;').endswith('0')
        rejects(owner + owner_topic + "insert into realtime.messages(extension) values('broadcast');")
        sql(owner + owner_topic + "insert into realtime.messages(extension) values('presence');")
        rejects(other + owner_topic + "insert into realtime.messages(extension) values('presence');")
        last_revision = int(sql(owner + 'select revision from public.remote_devices;').splitlines()[-1])
        sql(owner + 'delete from public.remote_devices;')
        sql(owner + patch)
        assert delta(last_revision)['device']['revision'] > last_revision
        assert len(delta(last_revision)['chats']) == 2
        print('PASS: all migrations, delete/recreate revision continuity, atomic event rollback, private channel RLS, compact signals, delta revisions/deletions, owner/project isolation, duplicate claims and no uncertain replay')
    finally:
        if started: run('pg_ctl','-D',folder/'data','-m','fast','-w','stop')
