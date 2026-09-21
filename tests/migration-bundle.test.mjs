import {test} from 'node:test';
import assert from 'node:assert/strict';
import {PGlite} from '@electric-sql/pglite';
import {readFile} from 'node:fs/promises';
test('atomic installation bundle preserves existing identities and registers one release job',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated;grant execute on function auth.uid() to authenticated;`);
 for(const n of ['001_tracker','002_admin_import','003_admin_bootstrap','004_training','005_catering','006_training_progress','007_staff_removal_it_roles','008_primary_jobs'])await db.exec(await readFile(new URL('../supabase/migrations/'+n+'.sql',import.meta.url),'utf8'));
 await db.exec("insert into auth.users values('00000000-0000-0000-0000-000000000001');insert into manager_profiles(id,name,is_admin) values('00000000-0000-0000-0000-000000000001','Existing IT',true);set request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';insert into staff(first_name,last_name,department) values('Existing','Person','FOH');create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text);alter table storage.objects enable row level security;create schema cron;create table cron.jobs(name text primary key,schedule text,command text);create function cron.schedule(text,text,text) returns int language plpgsql as $$begin insert into cron.jobs values($1,$2,$3) on conflict(name) do update set schedule=$2,command=$3;return 1;end $$;");
 const before=(await db.query('select id,first_name,last_name,department from staff')).rows;
 const bundle=(await readFile(new URL('../supabase/INSTALL_WORKSPACES.sql',import.meta.url),'utf8')).replace('create extension if not exists pg_cron;','-- pg_cron stub in local test only');await db.exec(bundle);
 assert.deepEqual((await db.query('select id,first_name,last_name,department from staff')).rows,before);
 assert.equal((await db.query('select count(*) n from private.employee_accounts')).rows[0].n,0);assert.equal((await db.query('select count(*) n from cron.jobs')).rows[0].n,1);
 await db.exec("select private.run_schedule_releases();set role authenticated");assert.deepEqual((await db.query('select workspace_session() r')).rows[0].r.views,['it','manager','employee']);
 }finally{await db.close()}
});
