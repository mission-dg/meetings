begin;
create function private.import_state() returns text language sql stable security definer set search_path='' as $$
 select md5(jsonb_build_object(
 'staff',(select coalesce(jsonb_agg(to_jsonb(s) order by id),'[]') from public.staff s),
 'jobs',(select coalesce(jsonb_agg(to_jsonb(j) order by id),'[]') from public.training_positions j),
 'qualifications',(select coalesce(jsonb_agg(to_jsonb(f) order by id),'[]') from public.training_signoffs f),
 'rates',(select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from private.pay_rates r),
 'managers',(select coalesce(jsonb_agg(to_jsonb(m) order by id),'[]') from public.manager_profiles m))::text)
$$;
create function private.import_job(p_name text) returns uuid language plpgsql stable security definer set search_path='' as $$
declare found_ids uuid[];name_value text:=trim(p_name);group_value text;
begin
 if nullif(name_value,'') is null then return null;end if;
 if position(':' in name_value)>0 then group_value:=upper(trim(split_part(name_value,':',1)));name_value:=trim(split_part(name_value,':',2));if group_value='HOH' then group_value:='BOH';end if;end if;
 select array_agg(id) into found_ids from public.training_positions where active and lower(trim(name))=lower(name_value) and (group_value is null or upper(department)=group_value);
 if coalesce(cardinality(found_ids),0)<>1 then raise exception 'Unknown, inactive or ambiguous role: %. Use Group: Job for ambiguous names.',p_name;end if;
 return found_ids[1];
end $$;
create function public.preview_employee_import(p_rows jsonb,p_effective date) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
    if dep is not null and dep not in ('FOH','BOH','Catering') then raise exception 'Choose FOH, HOH or Catering';end if;
    for role_name in select trim(value) from jsonb_array_elements_text(coalesce(r->'other_roles','[]')) loop
     jid:=private.import_job(role_name);if jid is not null and not jid=any(earned) then earned:=array_append(earned,jid);end if;
    end loop;
    if nullif(trim(r->>'hourly_wage'),'') is not null then
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
create function public.admin_import_staff(p_batch uuid,p_rows jsonb,p_effective date,p_fingerprint text) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.staff_imports;review jsonb;r jsonb;input jsonb;payload jsonb:=jsonb_build_object('rows',p_rows,'effective',p_effective,'fingerprint',p_fingerprint);result jsonb;staff_id text;j uuid;f public.training_signoffs;added int:=0;updated int:=0;skipped int:=0;before_staff jsonb;before_rate jsonb;
begin
 perform pg_advisory_xact_lock(61902028);perform pg_advisory_xact_lock(61902026);
 if not private.is_admin() then raise exception 'IT Admin access required';end if;
 if p_batch is null then raise exception 'Batch ID required';end if;
 select * into prior from private.staff_imports where batch_id=p_batch;
 if found then if prior.actor<>auth.uid() or prior.payload<>payload then raise exception 'Import changed. Review again';end if;return prior.result;end if;
 lock table public.staff,public.training_positions,public.training_signoffs,public.manager_profiles,private.pay_rates in share row exclusive mode;
 review:=public.preview_employee_import(p_rows,p_effective);
 if review->>'fingerprint' is distinct from p_fingerprint then raise exception 'Records changed since review. Preview the import again';end if;
 if jsonb_array_length(review->'errors')>0 then raise exception '%',review->'errors';end if;
 for r in select value from jsonb_array_elements(review->'rows') loop
  input:=p_rows->((r->>'row')::int-1);staff_id:=r->>'target_id';before_staff:=null;
  if r->>'action'='Skip' then skipped:=skipped+1;continue;end if;
  if r->>'action'='Add' then
   insert into public.staff(first_name,last_name,department,primary_job_id,active) values(trim(input->>'first_name'),trim(input->>'last_name'),r->>'department',(r->>'primary_id')::uuid,coalesce((input->>'active')::boolean,true)) returning id into staff_id;added:=added+1;
  else
   select to_jsonb(s) into before_staff from public.staff s where id=staff_id;
   if r->>'primary_id' is not null then update public.staff set primary_job_id=(r->>'primary_id')::uuid,department=r->>'department' where id=staff_id;end if;updated:=updated+1;
  end if;
  for j in select value::uuid from jsonb_array_elements_text(r->'earned_ids') loop
   if not private.job_qualified(staff_id,j) then
    insert into public.training_signoffs(staff_id,training_position_id,origin) values(staff_id,j,'migration') returning * into f;
    insert into private.qualification_history(staff_id,job_id,actor,action,reason,batch_id,after_value) values(staff_id,j,auth.uid(),'migration','Migration: previously trained',p_batch,to_jsonb(f));
   end if;
  end loop;
  if r->>'wage' is not null then
   select to_jsonb(pr) into before_rate from private.pay_rates pr where person_id='s:'||staff_id and effective=p_effective;
   insert into private.pay_rates(person_id,effective,hourly_rate) values('s:'||staff_id,p_effective,(r->>'wage')::numeric) on conflict(person_id,effective) do update set hourly_rate=excluded.hourly_rate,version=private.pay_rates.version+1;
   perform private.schedule_audit('import:wage',staff_id,before_rate,jsonb_build_object('hourly_rate',r->'wage','effective',p_effective,'batch_id',p_batch));
  end if;
  perform private.schedule_audit('import:employee',staff_id,before_staff,jsonb_build_object('batch_id',p_batch,'changes',r));
 end loop;
 result:=jsonb_build_object('added',added,'updated',updated,'skipped',skipped);insert into private.staff_imports values(p_batch,auth.uid(),payload,result);return result;
end $$;
revoke all on function private.import_state(),private.import_job(text),public.preview_employee_import(jsonb,date),public.admin_import_staff(uuid,jsonb,date,text) from public,anon;
revoke all on function private.import_state(),private.import_job(text) from authenticated;
grant execute on function public.preview_employee_import(jsonb,date),public.admin_import_staff(uuid,jsonb,date,text) to authenticated;
commit;
