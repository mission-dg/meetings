-- Owner-only, repeatable-read snapshot. No passwords, Auth tokens, or service keys.
begin isolation level repeatable read;
create table if not exists private.scheduler_backups (
 id text primary key, captured_at timestamptz not null default now(),
 records jsonb not null, functions jsonb not null, policies jsonb not null
);
alter table private.scheduler_backups enable row level security;
revoke all on private.scheduler_backups from public,anon,authenticated;
do $$
declare source text; bundle jsonb:='{}'; rows jsonb;
begin
 if exists(select 1 from private.scheduler_backups where id='before-scheduler-009') then return;end if;
 foreach source in array array['public.manager_profiles','public.staff','public.meetings','public.meeting_notes','public.gm_requests','public.training_sessions','public.training_positions','public.training_signoffs','public.change_history','private.tracker_setup','private.staff_imports'] loop
  execute format('select coalesce(jsonb_agg(to_jsonb(t)),''[]''::jsonb) from %s t',source) into rows;
  bundle:=bundle||jsonb_build_object(source,rows);
 end loop;
 insert into private.scheduler_backups(id,records,functions,policies)
 values('before-scheduler-009',bundle,
  (select coalesce(jsonb_agg(pg_get_functiondef(p.oid)),'[]') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prokind='f' and not exists(select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')),
  (select coalesce(jsonb_agg(to_jsonb(p)),'[]') from pg_policies p where schemaname in ('public','private')));
end $$;
commit;
select id,captured_at,(select jsonb_object_agg(key,jsonb_array_length(value)) from jsonb_each(records)) as record_counts from private.scheduler_backups where id='before-scheduler-009';
