begin;
create or replace function public.set_employee_role(p_id uuid,p_role text,p_version int,p_manager_version int,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare q record;job uuid;a private.employee_accounts;m public.manager_profiles;s public.staff;prior private.scheduler_submissions;payload jsonb:=jsonb_build_object('id',p_id,'role',p_role,'version',p_version,'manager_version',p_manager_version);
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.is_admin() then raise exception 'IT Admin access required';end if;
 if p_submission is null or p_role is null or p_role not in ('employee','ca','manager','it','hSHL','sSHL') then raise exception 'Choose an account role';end if;
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then if prior.actor<>auth.uid() or prior.action<>'employee_role' or prior.payload<>payload then raise exception 'Submission changed. Reload';end if;return prior.result;end if;
 select * into a from private.employee_accounts where id=p_id for update;
 select * into m from public.manager_profiles where id=p_id for update;
 if a.id is null or not a.active or p_version is null or a.version<>p_version or coalesce(m.version,0)<>coalesce(p_manager_version,0) then raise exception 'Account changed or inactive. Reload';end if;
 select * into s from public.staff where id=a.staff_id;
 if not s.active then raise exception 'Reactivate this employee before changing their role';end if;
 if m.id is not null and m.linked_staff_id is distinct from a.staff_id then raise exception 'Existing account links require IT review';end if;
 if m.active and m.is_gm and p_role in ('employee','ca','hSHL') then raise exception 'Assign a replacement GM before removing manager access';end if;
 if m.active and m.is_admin and p_role<>'it' and not exists(select 1 from public.manager_profiles where id<>p_id and active and is_admin) then raise exception 'Keep at least one active IT Admin';end if;
 -- Synchronize explicit leader selections with office eligibility and audited qualifications.
 if p_role in ('employee','ca','hSHL','sSHL') then
  for q in select f.* from public.training_signoffs f join public.training_positions j on j.id=f.training_position_id where f.staff_id=s.id and f.active and j.department='SHL' and j.name in ('hSHL','sSHL') and j.name<>p_role loop
   perform public.set_job_qualification(s.id,q.training_position_id,'revoke','Account permissions changed to '||p_role,q.version,gen_random_uuid());
  end loop;
  if p_role in ('hSHL','sSHL') then
   select id into job from public.training_positions where name=p_role and department='SHL' and active;
   if job is null then raise exception 'SHL job configuration missing';end if;
   if not private.job_qualified(s.id,job) then perform public.set_job_qualification(s.id,job,'override','Confirmed account assignment to '||p_role,0,gen_random_uuid());end if;
  end if;
 end if;
 update private.employee_accounts set is_ca=p_role='ca',version=version+1 where id=a.id;
 if p_role in ('manager','it','sSHL') then
  insert into public.manager_profiles(id,name,is_admin,linked_staff_id,on_roster) values(a.id,s.first_name||' '||s.last_name,p_role='it',s.id,true) on conflict(id) do update set active=true,is_admin=excluded.is_admin,employment_type=case when p_role='sSHL' then 'Salaried' else public.manager_profiles.employment_type end,version=public.manager_profiles.version+1;
 elsif m.id is not null then update public.manager_profiles set active=false,is_admin=false,version=version+1 where id=m.id;end if;
 perform private.schedule_audit('employee_role',a.id::text,jsonb_build_object('account',to_jsonb(a),'manager',to_jsonb(m)),jsonb_build_object('role',p_role,'staff_id',a.staff_id));
 insert into private.scheduler_submissions(id,actor,action,payload,result) values(p_submission,auth.uid(),'employee_role',payload,'{}');
 return '{}';
end $$;
commit;
