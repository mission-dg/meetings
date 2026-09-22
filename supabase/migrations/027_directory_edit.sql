begin;
create function private.directory_employee(p_staff text) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('staff_id',s.id,'first_name',s.first_name,'last_name',s.last_name,'primary_job',coalesce(j.name,''),'earned_jobs',coalesce((select jsonb_agg(p.name order by p.name) from public.training_signoffs f join public.training_positions p on p.id=f.training_position_id where f.staff_id=s.id and f.active),'[]'),'trainer_roles',coalesce((select jsonb_agg(p.name order by p.name) from public.training_positions p where p.id=any(s.trainer_job_ids)),'[]'),'revision',md5(to_jsonb(s)::text||coalesce((select jsonb_agg(to_jsonb(f) order by f.id)::text from public.training_signoffs f where f.staff_id=s.id),'[]')))
 from public.staff s left join public.training_positions j on j.id=s.primary_job_id where s.id=p_staff and s.active
$$;
create or replace function public.directory_csv_export() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not (private.is_admin() or private.is_gm()) then raise exception 'GM or IT access required';end if;
 return coalesce((select jsonb_agg(private.directory_employee(s.id) order by s.last_name,s.first_name,s.id) from public.staff s where s.active),'[]');
end $$;
create function private.directory_jobs(p_names jsonb,p_existing uuid[] default '{}') returns uuid[] language plpgsql stable security definer set search_path='' as $$
declare result uuid[]:='{}';label text;ids uuid[];
begin
 if jsonb_typeof(p_names) is distinct from 'array' then raise exception 'Use comma-separated job names';end if;
 for label in select trim(value) from jsonb_array_elements_text(p_names) loop
  if label='' then continue;end if;
  select array_agg(id) into ids from public.training_positions where lower(trim(name))=lower(label) and (active or id=any(p_existing));
  if cardinality(ids) is distinct from 1 then raise exception 'Unknown, inactive, or ambiguous job: %',label;end if;
  if not ids[1]=any(result) then result:=array_append(result,ids[1]);end if;
 end loop;return result;
end $$;
create function public.directory_csv_review(p_rows jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
   after_value:=jsonb_build_object('staff_id',s.id,'first_name',trim(row->>'first_name'),'last_name',trim(row->>'last_name'),'primary_job_id',primary_id,'primary_job',(select name from public.training_positions where id=primary_id),'earned_job_ids',to_jsonb(earned),'trainer_job_ids',to_jsonb(roles),'is_trainer',case when cardinality(roles)=0 and cardinality(s.trainer_job_ids)=0 then s.is_trainer else cardinality(roles)>0 end,'trainer_roles',row->'trainer_roles','qualifications_to_add',coalesce((select jsonb_agg(p.name order by p.name) from public.training_positions p where p.id=any(earned) and not p.id=any(old_earned)),'[]'));
   items:=items||jsonb_build_array(jsonb_build_object('row',num,'before',before_value,'after',after_value,'changed',s.first_name<>trim(row->>'first_name') or s.last_name<>trim(row->>'last_name') or s.primary_job_id is distinct from primary_id or not(s.trainer_job_ids @> roles and s.trainer_job_ids <@ roles) or s.is_trainer is distinct from (case when cardinality(roles)=0 and cardinality(s.trainer_job_ids)=0 then s.is_trainer else cardinality(roles)>0 end) or not old_earned @> earned));
  exception when others then raise exception 'Row %: %',num+1,sqlerrm;end;
 end loop;
 return jsonb_build_object('rows',items,'fingerprint',md5(items::text));
end $$;
create function public.directory_csv_apply(p_rows jsonb,p_fingerprint text,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.scheduler_submissions;review jsonb;item jsonb;row jsonb;before_value jsonb;result jsonb;job uuid;updated int:=0;payload jsonb:=jsonb_build_object('rows',p_rows,'fingerprint',p_fingerprint);
begin
 perform pg_advisory_xact_lock(61902028);perform pg_advisory_xact_lock(61902026);
 if not (private.is_admin() or private.is_gm()) then raise exception 'GM or IT access required';end if;
 if p_submission is null then raise exception 'Submission ID required';end if;
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then if prior.actor<>auth.uid() or prior.action<>'directory_csv' or prior.payload<>payload then raise exception 'Submission changed';end if;return prior.result;end if;
 -- Lock existing employees before reviewing to prevent concurrent staff edits.
 perform 1 from public.staff where id in (select value->>'staff_id' from jsonb_array_elements(p_rows)) order by id for update;
 review:=public.directory_csv_review(p_rows);
 if p_fingerprint is distinct from review->>'fingerprint' then raise exception 'Review changed. Review the CSV again';end if;
 for item in select value from jsonb_array_elements(review->'rows') loop
  if not (item->>'changed')::boolean then continue;end if;
  row:=item->'after';before_value:=item->'before';
  for job in select value::uuid from jsonb_array_elements_text(row->'earned_job_ids') loop
   if not exists(select 1 from public.training_signoffs where staff_id=row->>'staff_id' and training_position_id=job and active) then
    perform public.set_job_qualification(row->>'staff_id',job,'override','Directory CSV: previously trained. Batch '||p_submission::text,0,gen_random_uuid());
   end if;
  end loop;
  update public.staff set first_name=row->>'first_name',last_name=row->>'last_name',primary_job_id=(row->>'primary_job_id')::uuid,department=coalesce((select department from public.training_positions where id=(row->>'primary_job_id')::uuid),department),trainer_job_ids=array(select value::uuid from jsonb_array_elements_text(row->'trainer_job_ids')),is_trainer=(row->>'is_trainer')::boolean where id=row->>'staff_id';
  perform private.schedule_audit('directory_csv',row->>'staff_id',before_value,private.directory_employee(row->>'staff_id')||jsonb_build_object('batch_id',p_submission));updated:=updated+1;
 end loop;
 result:=jsonb_build_object('updated',updated,'unchanged',jsonb_array_length(p_rows)-updated);
 insert into private.scheduler_submissions values(p_submission,auth.uid(),'directory_csv',payload,result);return result;
end $$;
revoke all on function private.directory_employee(text),private.directory_jobs(jsonb,uuid[]) from public,anon,authenticated;
revoke all on function public.directory_csv_review(jsonb),public.directory_csv_apply(jsonb,text,uuid) from public,anon;
grant execute on function public.directory_csv_review(jsonb),public.directory_csv_apply(jsonb,text,uuid) to authenticated;
commit;
