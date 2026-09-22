begin;
alter table public.staff drop constraint staff_department_check;
alter table public.staff add constraint staff_department_check check(department in ('FOH','BOH','Catering','SHL'));
alter table public.training_positions drop constraint training_positions_department_check;
alter table public.training_positions add constraint training_positions_department_check check(department in ('FOH','BOH','Catering','SHL'));
alter table public.manager_profiles add column shl_job_managed boolean not null default false;
insert into public.training_positions(name,department,created_by)
select code,'SHL',(select id from public.manager_profiles where is_admin order by id limit 1)
from (values('hSHL'),('sSHL')) codes(code);

-- Job eligibility exists independently of a login. Only recorded qualifications grant it.
create function private.staff_shl_code(p_staff text) returns text language sql stable security definer set search_path='' as $$
 select j.name from public.training_signoffs f join public.training_positions j on j.id=f.training_position_id
 where f.staff_id=p_staff and f.active and j.department='SHL' and j.name in ('hSHL','sSHL') limit 1
$$;
create or replace function private.person_is_shl(p_person text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.manager_profiles where active and (case when linked_staff_id is null then 'm:'||id::text else 's:'||linked_staff_id end)=p_person)
 or exists(select 1 from public.staff where 's:'||id=p_person and active and private.staff_shl_code(id) is not null)
$$;
create or replace function private.person_employment(p_person text) returns text language sql stable security definer set search_path='' as $$
 select coalesce((select case private.staff_shl_code(id) when 'hSHL' then 'Hourly' when 'sSHL' then 'Salaried' end from public.staff where 's:'||id=p_person),
 (select employment_type from public.manager_profiles where active and (case when linked_staff_id is null then 'm:'||id::text else 's:'||linked_staff_id end)=p_person),'Hourly')
$$;
create function private.sync_shl_account(p_staff text) returns void language plpgsql security definer set search_path='' as $$
declare code text:=private.staff_shl_code(p_staff);a private.employee_accounts;s public.staff;m public.manager_profiles;before_value jsonb;
begin
 select * into a from private.employee_accounts where staff_id=p_staff;
 select * into s from public.staff where id=p_staff;
 if a.id is null then return;end if;
 select * into m from public.manager_profiles where id=a.id;
 if m.id is not null and m.linked_staff_id is distinct from p_staff then raise exception 'Account link requires IT review';end if;
 if m.is_admin or m.is_gm then return;end if;
 before_value:=case when m.id is null then null else to_jsonb(m) end;
 if code='sSHL' and a.active and s.active then
  insert into public.manager_profiles(id,name,linked_staff_id,employment_type,shl_job_managed,on_roster)
  values(a.id,s.first_name||' '||s.last_name,p_staff,'Salaried',true,true)
  on conflict(id) do update set active=true,employment_type='Salaried',shl_job_managed=true,version=public.manager_profiles.version+1;
 elsif m.id is not null and (code='hSHL' or m.shl_job_managed) then
  update public.manager_profiles set active=false,employment_type=case when code='hSHL' then 'Hourly' else employment_type end,version=version+1 where id=m.id;
 end if;
 if before_value is distinct from (select to_jsonb(x) from public.manager_profiles x where id=a.id) then
  perform private.schedule_audit('shl_job_access',p_staff,before_value,jsonb_build_object('code',code,'account',a.id));
 end if;
end $$;
create function private.shl_qualification_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare code text;
begin
 select name into code from public.training_positions where id=new.training_position_id and department='SHL' and name in ('hSHL','sSHL');
 if code is not null then
  if not(private.is_admin() or private.is_gm()) then raise exception 'GM or IT must approve SHL codes and access';end if;
  perform pg_advisory_xact_lock(61902028);
  if new.active and exists(select 1 from public.training_signoffs f join public.training_positions j on j.id=f.training_position_id where f.staff_id=new.staff_id and f.active and f.id<>new.id and j.department='SHL' and j.name in ('hSHL','sSHL') and j.name<>code) then
   raise exception 'Choose one SHL code. Revoke the previous SHL qualification before changing Hourly/Salaried';
  end if;
 end if;
 return new;
end $$;
create trigger shl_qualification_guard before insert or update on public.training_signoffs for each row execute function private.shl_qualification_guard();
create function private.shl_qualification_sync() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.training_positions where id=new.training_position_id and department='SHL' and name in ('hSHL','sSHL')) then perform private.sync_shl_account(new.staff_id);end if;
 return new;
end $$;
create trigger shl_qualification_sync after insert or update on public.training_signoffs for each row execute function private.shl_qualification_sync();
create function private.shl_account_sync() returns trigger language plpgsql security definer set search_path='' as $$
begin perform private.sync_shl_account(new.staff_id);return new;end $$;
create trigger shl_account_sync after insert or update of active,staff_id on private.employee_accounts for each row execute function private.shl_account_sync();
create function private.shl_profile_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.active and not new.is_admin and not new.is_gm and private.staff_shl_code(new.linked_staff_id)='hSHL' then raise exception 'hSHL does not grant schedule management. Use sSHL for salaried managers';end if;
 return new;
end $$;
create trigger shl_profile_guard before insert or update on public.manager_profiles for each row execute function private.shl_profile_guard();
-- The SHL codes are reserved, so renaming a job cannot silently change access.
create function private.shl_job_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if (old.department='SHL' and old.name in ('hSHL','sSHL')) or (new.department='SHL' and new.name in ('hSHL','sSHL')) then
  if new.name is distinct from old.name or new.department is distinct from old.department or new.active is distinct from old.active then raise exception 'SHL codes are reserved. Change employee qualifications instead';end if;
 end if;return new;
end $$;
create trigger shl_job_guard before update on public.training_positions for each row execute function private.shl_job_guard();
revoke all on function private.staff_shl_code(text),private.sync_shl_account(text),private.shl_qualification_guard(),private.shl_qualification_sync(),private.shl_account_sync(),private.shl_profile_guard(),private.shl_job_guard() from public,anon,authenticated;
create or replace function public.directory_csv_review(p_rows jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare row jsonb;before_value jsonb;after_value jsonb;items jsonb:='[]';s public.staff;primary_id uuid;earned uuid[];roles uuid[];old_earned uuid[];ids text[]:='{}';num int:=0;
begin
 if not (private.is_admin() or private.is_gm()) then raise exception 'GM or IT access required';end if;
 if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 500 then raise exception 'Include 1–500 employee rows';end if;
 for row in select value from jsonb_array_elements(p_rows) loop
  num:=num+1;
  begin
   if row->>'staff_id'=any(ids) then raise exception 'Duplicate employee ID';end if;ids:=array_append(ids,row->>'staff_id');
   select * into s from public.staff where id=row->>'staff_id' and active;
   if s.id is null then raise exception 'Unknown or inactive employee ID';end if;
   before_value:=private.directory_employee(s.id);
   if row->>'revision' is distinct from before_value->>'revision' then raise exception 'Employee or qualifications changed. Download a fresh CSV';end if;
   if length(trim(coalesce(row->>'first_name',''))) not between 1 and 100 or length(trim(coalesce(row->>'last_name',''))) not between 1 and 100 then raise exception 'Enter first and last names (up to 100 characters)';end if;
   select coalesce(array_agg(training_position_id),'{}') into old_earned from public.training_signoffs where staff_id=s.id and active;
   earned:=private.directory_jobs(row->'earned_jobs',old_earned);
   roles:=private.directory_jobs(row->'trainer_roles',s.trainer_job_ids);
   primary_id:=s.primary_job_id;
   if trim(coalesce(row->>'primary_job',''))<>'' and row->>'primary_job' is distinct from before_value->>'primary_job' then
    primary_id:=(private.directory_jobs(jsonb_build_array(row->>'primary_job')))[1];
    if not primary_id=any(old_earned||earned) then raise exception 'Primary job must already be qualified or included in Earned jobs';end if;
   end if;
   if (select count(distinct j.name) from public.training_positions j where j.id=any(old_earned||earned) and j.department='SHL' and j.name in ('hSHL','sSHL'))>1 then raise exception 'Choose one SHL code. Revoke the previous SHL qualification first';end if;
   after_value:=jsonb_build_object('staff_id',s.id,'first_name',trim(row->>'first_name'),'last_name',trim(row->>'last_name'),'primary_job_id',primary_id,'primary_job',(select name from public.training_positions where id=primary_id),'earned_job_ids',to_jsonb(earned),'trainer_job_ids',to_jsonb(roles),'is_trainer',case when cardinality(roles)=0 and cardinality(s.trainer_job_ids)=0 then s.is_trainer else cardinality(roles)>0 end,'trainer_roles',row->'trainer_roles','qualifications_to_add',coalesce((select jsonb_agg(p.name order by p.name) from public.training_positions p where p.id=any(earned) and not p.id=any(old_earned)),'[]'));
   items:=items||jsonb_build_array(jsonb_build_object('row',num,'before',before_value,'after',after_value,'changed',s.first_name<>trim(row->>'first_name') or s.last_name<>trim(row->>'last_name') or s.primary_job_id is distinct from primary_id or not(s.trainer_job_ids @> roles and s.trainer_job_ids <@ roles) or s.is_trainer is distinct from (case when cardinality(roles)=0 and cardinality(s.trainer_job_ids)=0 then s.is_trainer else cardinality(roles)>0 end) or not old_earned @> earned));
  exception when others then raise exception 'Row %: %',num+1,sqlerrm;end;
 end loop;
 return jsonb_build_object('rows',items,'fingerprint',md5(items::text));
end $$;
create or replace function public.preview_employee_import(p_rows jsonb,p_effective date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;outrows jsonb:='[]';errors text[]:='{}';n integer:=0;ids text[];seen text[]:='{}';new_names text[]:='{}';name_key text;s public.staff;pid uuid;jid uuid;earned uuid[];role_name text;dep text;action text;target text;wage numeric;old_rate private.pay_rates;choices text;row_errors text[];row_value jsonb;
begin
 if not private.is_admin() then raise exception 'IT Admin access required';end if;
 if p_effective is null or not isfinite(p_effective) then raise exception 'Choose a wage effective date';end if;
 if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 500 then raise exception 'Import between 1 and 500 employees';end if;
 for r in select value from jsonb_array_elements(p_rows) loop
  n:=n+1;s:=null;old_rate:=null;pid:=null;earned:='{}';wage:=null;target:=null;action:='Add';row_errors:='{}';ids:='{}';dep:=null;row_value:='{}';
  begin
   if r->>'choice'='skip' then action:='Skip';
   else
    if nullif(trim(r->>'staff_id'),'') is not null then
     select * into s from public.staff where id=trim(r->>'staff_id');if s.id is null then raise exception 'Unknown Staff ID';end if;
    elsif nullif(r->>'target_id','') is not null then
     select * into s from public.staff where id=r->>'target_id';if s.id is null then raise exception 'Selected employee is unavailable';end if;
    elsif r->>'choice' is distinct from 'create' then
     select array_agg(id order by id) into ids from public.staff where lower(trim(first_name))=lower(trim(r->>'first_name')) and lower(trim(last_name))=lower(trim(r->>'last_name'));
     if cardinality(ids)=1 then select * into s from public.staff where id=ids[1];row_errors:=array_append(row_errors,'Confirm the suggested existing employee or choose Create new');
     elsif cardinality(ids)>1 then row_errors:=array_append(row_errors,'Multiple people match. Select an employee or explicitly choose Create new');end if;
    end if;
    target:=s.id;if target is not null then action:='Update';end if;
    if cardinality(ids)>1 and target is null then action:='Match required';end if;
    if target=any(seen) then raise exception 'Two rows target the same employee';end if;
    if target is not null then seen:=array_append(seen,target);end if;
    if action='Add' and (length(trim(coalesce(r->>'first_name',''))) not between 1 and 100 or length(trim(coalesce(r->>'last_name',''))) not between 1 and 100) then raise exception 'Enter first and last name';end if;
    if action='Add' then name_key:=lower(trim(r->>'first_name'))||chr(31)||lower(trim(r->>'last_name'));if name_key=any(new_names) and r->>'choice' is distinct from 'create' then raise exception 'Duplicate new employee name. Explicitly choose Create new only for different people';end if;new_names:=array_append(new_names,name_key);end if;
    pid:=private.import_job(r->>'primary_role');
    dep:=nullif(r->>'department','');
    if pid is not null then
     if dep is not null and dep<>(select department from public.training_positions where id=pid) then raise exception 'Position group conflicts with Primary Role';end if;
     dep:=(select department from public.training_positions where id=pid);earned:=array_append(earned,pid);
    elsif action='Add' then raise exception 'New employees require a Primary Role';end if;
    if dep is not null and dep not in ('FOH','BOH','Catering','SHL') then raise exception 'Choose FOH, HOH, Catering or SHL';end if;
    for role_name in select trim(value) from jsonb_array_elements_text(coalesce(r->'other_roles','[]')) loop
     jid:=private.import_job(role_name);if jid is not null and not jid=any(earned) then earned:=array_append(earned,jid);end if;
    end loop;
    if (select count(distinct j.name) from public.training_positions j where (j.id=any(earned) or exists(select 1 from public.training_signoffs f where f.staff_id=target and f.active and f.training_position_id=j.id)) and j.department='SHL' and j.name in ('hSHL','sSHL'))>1 then raise exception 'Choose one SHL code. Revoke the previous SHL qualification first';end if;
    if nullif(trim(r->>'hourly_wage'),'') is not null then
     if exists(select 1 from public.training_positions where id=any(earned) and department='SHL' and name='sSHL') then raise exception 'Hourly wages cannot be imported for a salaried SHL';end if;
     if trim(r->>'hourly_wage') !~ '^[0-9]+([.][0-9]{1,2})?$' then raise exception 'Hourly Wage needs a nonnegative amount with at most two decimal places';end if;
     wage:=(r->>'hourly_wage')::numeric;if wage>=100000 then raise exception 'Hourly Wage must be below 100000';end if;
     if target is not null and private.person_employment('s:'||target)='Salaried' then raise exception 'Hourly wages cannot be imported for a salaried SHL';end if;
     select * into old_rate from private.pay_rates where person_id='s:'||target and effective=p_effective;
    end if;
    row_value:=jsonb_build_object('primary_id',pid,'department',dep,'earned_ids',earned,'wage',wage,'before',jsonb_build_object('primary_role',(select name from public.training_positions where id=s.primary_job_id),'qualifications',(select coalesce(jsonb_agg(j.name order by j.name),'[]') from public.training_signoffs f join public.training_positions j on j.id=f.training_position_id where f.staff_id=target and f.active),'wage_on_date',old_rate.hourly_rate,'current_wage',(select hourly_rate from private.pay_rates where person_id='s:'||target and effective<=p_effective order by effective desc limit 1)),'after',jsonb_build_object('primary_role',coalesce((select name from public.training_positions where id=pid),(select name from public.training_positions where id=s.primary_job_id)),'qualifications_to_add',(select coalesce(jsonb_agg(j.name order by j.name),'[]') from public.training_positions j where j.id=any(earned) and not private.job_qualified(target,j.id)),'hourly_wage',wage,'effective',p_effective));
   end if;
  exception when others then row_errors:=array_append(row_errors,sqlerrm);
  end;
  foreach choices in array row_errors loop errors:=array_append(errors,'Row '||(n+1)||': '||choices);end loop;
  outrows:=outrows||jsonb_build_array(row_value||jsonb_build_object('row',n,'action',action,'target_id',target,'suggested_ids',ids,'name',case when s.id is not null then s.first_name||' '||s.last_name else concat_ws(' ',r->>'first_name',r->>'last_name') end,'errors',row_errors));
 end loop;
 return jsonb_build_object('rows',outrows,'errors',errors,'fingerprint',md5(private.import_state()||p_rows::text||p_effective::text));
end $$;
create or replace function public.set_shl_employment(p_person text,p_type text,p_version integer) returns void language plpgsql security definer set search_path='' as $$
declare m public.manager_profiles;before_value jsonb;
begin
 perform pg_advisory_xact_lock(61902028);
 if not(private.is_admin() or private.is_gm()) then raise exception 'GM or IT access required';end if;
 if p_type is null or p_type not in ('Hourly','Salaried') then raise exception 'Choose Hourly or Salaried';end if;
 select * into m from public.manager_profiles where active and (case when linked_staff_id is null then 'm:'||id::text else 's:'||linked_staff_id end)=p_person for update;
 if m.id is null or m.version is distinct from p_version then raise exception 'Manager changed. Reload';end if;
 if private.staff_shl_code(m.linked_staff_id) is not null then raise exception 'Change hSHL/sSHL through employee qualifications';end if;
 before_value:=to_jsonb(m);update public.manager_profiles set employment_type=p_type,version=version+1 where id=m.id;
 perform private.schedule_audit('employment_type',p_person,before_value,jsonb_build_object('employment_type',p_type));
end $$;
commit;
