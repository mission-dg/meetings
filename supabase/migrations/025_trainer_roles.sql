begin;
alter table public.staff add column trainer_job_ids uuid[] not null default '{}';
-- Existing trainer flags remain, with no roles inferred from past sessions.
create function private.validate_trainer_roles() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not new.is_trainer then new.trainer_job_ids:='{}';end if;
 if TG_OP='INSERT' or new.is_trainer is distinct from old.is_trainer or new.trainer_job_ids is distinct from old.trainer_job_ids then
  if new.is_trainer and cardinality(new.trainer_job_ids)=0 then raise exception 'Select at least one trainer role';end if;
  if exists(select 1 from unnest(new.trainer_job_ids) j where not exists(select 1 from public.training_positions p where p.id=j and p.active)) then raise exception 'Choose active trainer roles';end if;
  new.trainer_job_ids:=array(select distinct unnest(new.trainer_job_ids));
 end if;
 return new;
end $$;
create trigger trainer_roles_validation before insert or update on public.staff for each row execute function private.validate_trainer_roles();
create or replace function public.save_employee(p_id text,p_version integer,p_values jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.staff;j public.training_positions;
begin
 perform pg_advisory_xact_lock(61902028);perform pg_advisory_xact_lock(61902026);
 if not private.is_manager() then raise exception 'Manager access required';end if;
 select * into j from public.training_positions where id=(p_values->>'primary_job_id')::uuid and active;
 if j.id is null then raise exception 'Choose an active primary job';end if;
 if p_id is null then
  if not private.is_admin() then raise exception 'IT access required to add employees';end if;
  insert into public.staff(first_name,last_name,department,primary_job_id,active,priority,is_trainer,trainer_job_ids) values(trim(p_values->>'first_name'),trim(p_values->>'last_name'),j.department,j.id,coalesce((p_values->>'active')::boolean,true),coalesce((p_values->>'priority')::boolean,false),coalesce((p_values->>'is_trainer')::boolean,false),array(select jsonb_array_elements_text(coalesce(p_values->'trainer_job_ids','[]'))::uuid)) returning * into s;
 else
  select * into s from public.staff where id=p_id for update;
  if s.id is null or s.version is distinct from p_version then raise exception 'Employee changed. Reload';end if;
  if not private.is_admin() and (s.first_name is distinct from p_values->>'first_name' or s.last_name is distinct from p_values->>'last_name' or s.active is distinct from (p_values->>'active')::boolean) then raise exception 'IT manages employee names and access';end if;
  update public.staff set first_name=trim(p_values->>'first_name'),last_name=trim(p_values->>'last_name'),department=j.department,primary_job_id=j.id,active=(p_values->>'active')::boolean,priority=(p_values->>'priority')::boolean,is_trainer=(p_values->>'is_trainer')::boolean,trainer_job_ids=case when p_values ? 'trainer_job_ids' then array(select jsonb_array_elements_text(p_values->'trainer_job_ids')::uuid) else s.trainer_job_ids end where id=p_id returning * into s;
 end if;return to_jsonb(s);
end $$;

create function private.validate_training_trainer_role() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='Scheduled' and (TG_OP='INSERT' or new.trainer_id is distinct from old.trainer_id or new.training_position_id is distinct from old.training_position_id or new.scheduled_at is distinct from old.scheduled_at or new.work_shift_id is distinct from old.work_shift_id or new.trainer_shift_id is distinct from old.trainer_shift_id or new.ends_at is distinct from old.ends_at or old.status<>'Scheduled') then
  if not exists(select 1 from public.staff s where s.id=new.trainer_id and s.active and s.is_trainer and new.training_position_id=any(s.trainer_job_ids)) then raise exception 'Choose a trainer designated for this job';end if;
 end if;
 return new;
end $$;
create trigger training_trainer_role_validation before insert or update on public.training_sessions for each row execute function private.validate_training_trainer_role();
alter function public.scheduler_read(date) rename to scheduler_read_before_trainer_roles;
revoke all on function public.scheduler_read_before_trainer_roles(date) from public,anon,authenticated;
create function public.scheduler_read(p_week date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 r:=public.scheduler_read_before_trainer_roles(p_week);
 return jsonb_set(r,'{people}',coalesce((select jsonb_agg(p||jsonb_build_object('trainer_job_ids',coalesce((select to_jsonb(s.trainer_job_ids) from public.staff s where s.id=p->>'staff_id'),'[]'::jsonb))) from jsonb_array_elements(r->'people') p),'[]'));
end $$;
revoke all on function private.validate_trainer_roles(),private.validate_training_trainer_role() from public,anon,authenticated;
revoke all on function public.scheduler_read(date) from public,anon;
grant execute on function public.scheduler_read(date) to authenticated;
commit;
