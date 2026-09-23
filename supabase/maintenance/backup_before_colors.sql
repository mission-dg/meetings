-- Run as the project owner before migration 037. Keep this snapshot inside Supabase.
begin isolation level repeatable read;
create table if not exists private.scheduler_backups (
 id text primary key, captured_at timestamptz not null default now(),
 records jsonb not null, functions jsonb not null, policies jsonb not null
);
alter table private.scheduler_backups enable row level security;
revoke all on private.scheduler_backups from public,anon,authenticated;
do $$
declare source text;bundle jsonb:='{}';rows jsonb;backup_id text:='before-colors-037-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSUS');
begin
 foreach source in array array['public.staff','public.manager_profiles','public.training_positions','public.training_signoffs','public.training_sessions','public.change_history','private.qualification_history','private.employee_accounts','private.schedule_weeks','private.schedule_revisions','private.scheduler_notifications','private.scheduler_audit','private.staff_imports','private.staff_meetings'] loop
  execute format('select coalesce(jsonb_agg(to_jsonb(t)),''[]''::jsonb) from %s t',source) into rows;
  bundle:=bundle||jsonb_build_object(source,rows);
 end loop;
 insert into private.scheduler_backups(id,records,functions,policies) values(backup_id,bundle,
  (select coalesce(jsonb_agg(pg_get_functiondef(p.oid)),'[]') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prokind='f' and not exists(select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')),
  (select coalesce(jsonb_agg(to_jsonb(p)),'[]') from pg_policies p where schemaname in ('public','private')));
end $$;
commit;
-- Metadata only: do not export the snapshot's private employee records.
select id,captured_at from private.scheduler_backups where id like 'before-colors-037-%' order by captured_at desc limit 1;
