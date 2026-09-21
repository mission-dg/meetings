begin;
create table public.training_positions (
 id uuid primary key default gen_random_uuid(), name text not null check(length(trim(name)) between 1 and 100),
 department text not null check(department in ('FOH','BOH','Catering')),
 target_shifts integer not null default 4 check(target_shifts between 1 and 30), active boolean not null default true,
 created_by uuid not null default auth.uid() references public.manager_profiles(id),
 created_at timestamptz not null default now(), version integer not null default 1
);
create unique index training_position_name on public.training_positions(department,lower(trim(name)));
alter table public.training_sessions add column training_position_id uuid references public.training_positions(id);
create table public.training_signoffs (
 id uuid primary key default gen_random_uuid(), staff_id text not null references public.staff(id),
 training_position_id uuid not null references public.training_positions(id),
 active boolean not null default true, created_by uuid not null default auth.uid() references public.manager_profiles(id),
 created_at timestamptz not null default now(), version integer not null default 1
);
create unique index one_active_training_signoff on public.training_signoffs(staff_id,training_position_id) where active;
create function private.training_completed_shifts(p_staff text,p_position uuid) returns integer language sql stable security definer set search_path='' as $$
 select count(distinct ((scheduled_at at time zone 'America/Chicago')::date,shift))::integer from public.training_sessions where staff_id=p_staff and training_position_id=p_position and status='Completed';
$$;
revoke all on function private.training_completed_shifts(text,uuid) from public,anon,authenticated;
create function private.validate_training_progress() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='training_sessions' then
  if new.status='Completed' and new.scheduled_at>now() then raise exception 'A future training shift cannot be marked completed';end if;
  if TG_OP='INSERT' or new.training_position_id is distinct from old.training_position_id or (new.status='Completed' and old.status<>'Completed') then
   if not exists(select 1 from public.training_positions where id=new.training_position_id and active) then raise exception 'Choose an active training job';end if;
  end if;
  return new;
 end if;
 if TG_OP='UPDATE' then
  if new.id<>old.id or new.created_by<>old.created_by or new.created_at<>old.created_at then raise exception 'Record ownership cannot change';end if;
  if new.version<>old.version then raise exception 'Reload this record before editing';end if;
  new.version:=old.version+1;
 end if;
 if TG_TABLE_NAME='training_signoffs' then
  if TG_OP='UPDATE' and (new.staff_id<>old.staff_id or new.training_position_id<>old.training_position_id) then raise exception 'Employee and training job cannot change on a sign-off';end if;
  if new.active then
   perform pg_advisory_xact_lock(hashtextextended(new.staff_id||new.training_position_id::text,0));
   if not exists(select 1 from public.staff where id=new.staff_id and active) then raise exception 'Choose an active employee';end if;
   if not exists(select 1 from public.training_positions where id=new.training_position_id and active and private.training_completed_shifts(new.staff_id,new.training_position_id)>=target_shifts) then raise exception 'Complete the target number of training shifts before signing off';end if;
  end if;
 end if;
 return new;
end $$;
create trigger training_job_validation before insert or update on public.training_sessions for each row execute function private.validate_training_progress();
create trigger training_position_validation before insert or update on public.training_positions for each row execute function private.validate_training_progress();
create trigger training_signoff_validation before insert or update on public.training_signoffs for each row execute function private.validate_training_progress();
create trigger audit_training_position after insert or update on public.training_positions for each row execute function private.audit_change();
create trigger audit_training_signoff after insert or update on public.training_signoffs for each row execute function private.audit_change();
alter table public.training_positions enable row level security;
alter table public.training_signoffs enable row level security;
revoke all on public.training_positions,public.training_signoffs from anon,authenticated;
grant select,insert,update on public.training_positions,public.training_signoffs to authenticated;
create policy managers_read_training_positions on public.training_positions for select to authenticated using(private.is_manager());
create policy admins_add_training_positions on public.training_positions for insert to authenticated with check(private.is_admin() and created_by=auth.uid());
create policy admins_edit_training_positions on public.training_positions for update to authenticated using(private.is_admin()) with check(private.is_admin());
create policy managers_read_training_signoffs on public.training_signoffs for select to authenticated using(private.is_manager());
create policy managers_add_training_signoffs on public.training_signoffs for insert to authenticated with check(private.is_manager() and created_by=auth.uid());
create policy creators_edit_training_signoffs on public.training_signoffs for update to authenticated using(private.is_manager() and created_by=auth.uid()) with check(private.is_manager() and created_by=auth.uid());
insert into public.training_positions(name,department,created_by)
select seed.name,seed.department,owner.id from (values ('GSR','FOH'),('EXPO','FOH'),('DRL','FOH'),('Line','BOH'),('Prep','BOH'),('Catering','Catering')) seed(name,department)
cross join (select id from public.manager_profiles where active and is_admin order by id limit 1) owner;
commit;
