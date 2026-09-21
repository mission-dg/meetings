begin;
-- Additive upgrade; existing IDs and historical approvals are preserved.
create or replace function private.person_conflict(p_person text,p_start timestamptz,p_end timestamptz) returns text language plpgsql stable security definer set search_path='' as $$
declare d date; a jsonb; av_window jsonb; lo int; hi int; covered boolean; local_start timestamp:=p_start at time zone 'America/Chicago';local_end timestamp:=p_end at time zone 'America/Chicago';
begin
 if exists(select 1 from private.scheduler_requests where person_id=p_person and kind='Time off' and status='Approved' and (payload->>'start')::timestamptz<p_end and (payload->>'end')::timestamptz>p_start) then return 'Approved time off';end if;
 for d in select generate_series(local_start::date,local_end::date,interval '1 day')::date loop
  lo:=case when d=local_start::date then extract(hour from local_start)::int*60+extract(minute from local_start)::int else 0 end;
  hi:=case when d=local_end::date then extract(hour from local_end)::int*60+extract(minute from local_end)::int else 1440 end;
  if hi=lo then continue;end if;
  select payload into a from private.scheduler_requests where person_id=p_person and kind='Availability' and status='Approved' and (payload->>'effective')::date<=d and (nullif(payload->>'until','') is null or (payload->>'until')::date>=d) order by (nullif(payload->>'until','') is not null) desc,(payload->>'effective')::date desc,created_at desc,id desc limit 1;
  if a is not null then
   covered:=false;
   for av_window in select value from jsonb_array_elements(a->'days'->extract(dow from d)::int) loop
    if (av_window->>0)::int<=lo and (av_window->>1)::int>lo then lo:=(av_window->>1)::int;end if;
    if lo>=hi then covered:=true;exit;end if;
   end loop;
   if not covered then return 'Outside approved availability';end if;
  end if;
 end loop;return null;
end $$;


create function public.workspace_session() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.scheduler_member() then raise exception 'Active workspace access required';end if;
 return jsonb_build_object('id',auth.uid(),'name',private.account_name(auth.uid()),'person_id',private.my_person(),'views',case when private.is_admin() then jsonb_build_array('it','manager','employee') when private.is_manager() then jsonb_build_array('manager','employee') else jsonb_build_array('employee') end,'is_ca',private.is_ca());
end $$;
create function public.workspace_read(p_week date,p_view text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb; me text:=private.my_person(); sid text:=private.employee_staff(); ca boolean:=private.is_ca(); g text;
begin
 if p_view not in ('employee','manager','it') or p_view is null then raise exception 'Choose an available workspace';end if;
 if p_view='it' and not private.is_admin() or p_view='manager' and not private.is_manager() then raise exception 'This workspace is not available to your account';end if;
 r:=public.scheduler_read(p_week);
 r:=r||jsonb_build_object('workspace',p_view,'available_views',public.workspace_session()->'views');
 if p_view='employee' then
  r:=jsonb_set(r,'{self}',(r->'self')||jsonb_build_object('is_manager',false,'is_admin',false));
  r:=jsonb_set(r,'{week,draft}','null');
  r:=r||jsonb_build_object('accounts','[]'::jsonb,'service','{}'::jsonb,'audit','[]'::jsonb,'releases','[]'::jsonb);
  r:=jsonb_set(r,'{published}',coalesce((select jsonb_agg(w||jsonb_build_object('shifts',(select coalesce(jsonb_agg(s-'qualification_reason'),'[]') from jsonb_array_elements(w->'shifts') s))) from jsonb_array_elements(r->'published') w),'[]'));
  r:=jsonb_set(r,'{training}',coalesce((select jsonb_agg(t) from jsonb_array_elements(r->'training') t where private.training_visible((t->>'schedule_revision_id')::uuid) and (ca or t->>'staff_id'=sid or t->>'trainer_id'=sid)),'[]'));
  r:=jsonb_set(r,'{signoffs}',coalesce((select jsonb_agg(f) from jsonb_array_elements(r->'signoffs') f where ca or f->>'staff_id'=sid),'[]'));
  r:=jsonb_set(r,'{requests}',coalesce((select jsonb_agg(case when q->>'created_by'=auth.uid()::text then q else q-'reason'-'response' end) from jsonb_array_elements(r->'requests') q where q->>'created_by'=auth.uid()::text or q->>'claimed_by'=auth.uid()::text or q->'payload'->>'recipient'=me or q->>'kind'='Offer' and q->>'status'='Pending'),'[]'));
  -- Manager notifications are not employee-facing merely because the account has both roles.
  r:=jsonb_set(r,'{notifications}',coalesce((select jsonb_agg(n) from jsonb_array_elements(r->'notifications') n where n->>'event_key' ~ '^(schedule:|decision:|revoke:|accepted:|invalid:)' or exists(select 1 from private.scheduler_requests q where n->>'event_key'='request:'||q.id and q.kind in ('Trade','Coverage') and q.payload->>'recipient'=me)),'[]'));
  r:=jsonb_set(r,'{people}',coalesce((select jsonb_agg(p-'version') from jsonb_array_elements(r->'people') p where (p->>'active')::boolean or p->>'id'=me or exists(select 1 from private.published_shifts() s where s->>'person_id'=p->>'id')),'[]'));
 end if;
 return r;
end $$;
alter table private.scheduler_requests drop constraint scheduler_requests_kind_check;
alter table private.scheduler_requests add constraint scheduler_requests_kind_check check(kind in ('Availability','Time off','Trade','Coverage','Offer','Cancel time off'));
-- Preserve the tested scheduler transaction as an internal implementation.
alter function public.scheduler_action(text,jsonb,uuid) set schema private;
alter function private.scheduler_action(text,jsonb,uuid) rename to scheduler_action_v1;
revoke all on function private.scheduler_action_v1(text,jsonb,uuid) from public,anon,authenticated;
create function public.scheduler_action(p_action text,p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.scheduler_submissions; q private.scheduler_requests; oldq private.scheduler_requests; result jsonb; before_value jsonb; d jsonb; until_date date; replace_id uuid; paid numeric; r record; issues text[]; new_id uuid;
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.scheduler_member() then raise exception 'Active workspace access required';end if;
 if p_submission is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Submission information is required';end if;
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then
  if prior.actor<>auth.uid() or prior.action<>p_action or prior.payload<>p_payload then raise exception 'Submission changed. Reload before saving';end if;
  return prior.result;
 end if;
 if p_action='request' and p_payload->>'kind'='Availability' then
  d:=p_payload->'details';until_date:=nullif(d->>'until','')::date;
  if until_date is not null and until_date<(d->>'effective')::date then raise exception 'Availability end date must be on or after the start date';end if;
 elsif p_action='request' and p_payload->>'kind'='Time off' then
  d:=p_payload->'details';
  if d->>'category' is null or d->>'category' not in ('PTO','RTO') then raise exception 'Choose PTO or RTO';end if;
  if d->>'category'='PTO' then
   paid:=(d->>'paid_hours')::numeric;
   if paid is null or paid<=0 or paid='NaN'::numeric or paid>extract(epoch from ((d->>'end')::timestamptz-(d->>'start')::timestamptz))/3600 then raise exception 'Enter positive paid hours within the requested interval';end if;
  elsif nullif(d->>'paid_hours','') is not null then raise exception 'Paid hours apply only to PTO';end if;
 end if;
 if p_action in ('decide','withdraw','revoke','cancel_time_off') then
  select * into q from private.scheduler_requests where id=(p_payload->>'id')::uuid for update;
  if q.id is null or p_payload->>'version' is null or q.version<>(p_payload->>'version')::int then raise exception 'This request changed. Reload';end if;
 end if;
 if p_action='decide' and p_payload->>'decision'='Approved' and q.kind='Availability' then
  if not private.is_manager() or q.created_by=auth.uid() or q.status<>'Pending' then raise exception 'Another manager must decide this pending request';end if;
  replace_id:=nullif(p_payload->>'replace_id','')::uuid;
  if replace_id is not null then
   select * into oldq from private.scheduler_requests where id=replace_id for update;
   if oldq.id is null or oldq.person_id<>q.person_id or oldq.kind<>'Availability' or oldq.status<>'Approved' or nullif(oldq.payload->>'until','') is null or p_payload->>'replace_version' is null or oldq.version<>(p_payload->>'replace_version')::int then raise exception 'The temporary approval to replace changed. Reload';end if;
   update private.scheduler_requests set status='Withdrawn',version=version+1,response='Replaced by an explicitly reviewed temporary availability approval',decided_by=auth.uid(),decided_at=now() where id=oldq.id;
   perform private.schedule_audit('replace_availability',oldq.id::text,to_jsonb(oldq),(select to_jsonb(x) from private.scheduler_requests x where x.id=oldq.id));
  end if;
  if nullif(q.payload->>'until','') is not null and exists(select 1 from private.scheduler_requests x where x.person_id=q.person_id and x.kind='Availability' and x.status='Approved' and nullif(x.payload->>'until','') is not null and (x.payload->>'effective')::date<=(q.payload->>'until')::date and (x.payload->>'until')::date>=(q.payload->>'effective')::date) then raise exception 'This overlaps an approved temporary pattern. Select the approval to replace';end if;
 end if;
 if p_action='cancel_time_off' then
  if q.created_by<>auth.uid() or q.kind<>'Time off' or q.status<>'Approved' then raise exception 'Choose your own approved time off';end if;
  if exists(select 1 from private.scheduler_requests where kind='Cancel time off' and status='Pending' and payload->>'request_id'=q.id::text) then raise exception 'Cancellation is already awaiting approval';end if;
  insert into private.scheduler_requests(kind,person_id,created_by,payload,reason) values('Cancel time off',q.person_id,auth.uid(),jsonb_build_object('request_id',q.id,'request_version',q.version,'start',q.payload->>'start','end',q.payload->>'end','category',q.payload->>'category'),left(coalesce(p_payload->>'reason',''),2000)) returning id into new_id;
  result:=jsonb_build_object('id',new_id);
  perform private.notify_managers('request:'||new_id,'A time-off cancellation needs approval. The approved absence remains in effect.');
 elsif p_action='decide' and q.kind='Cancel time off' then
  if not private.is_manager() or q.created_by=auth.uid() or q.status<>'Pending' then raise exception 'Another manager must decide this pending request';end if;
  if p_payload->>'decision' is null or p_payload->>'decision' not in ('Approved','Rejected') then raise exception 'Choose an approval decision';end if;
  before_value:=to_jsonb(q);
  if p_payload->>'decision'='Approved' then
   select * into oldq from private.scheduler_requests where id=(q.payload->>'request_id')::uuid for update;
   if oldq.status<>'Approved' or oldq.version<>(q.payload->>'request_version')::int then raise exception 'The approved time off changed. Withdraw this cancellation and review the current request';end if;
   update private.scheduler_requests set status='Withdrawn',version=version+1,decided_by=auth.uid(),decided_at=now(),response='Cancellation approved' where id=oldq.id;
   perform private.schedule_audit('cancel_approved_time_off',oldq.id::text,to_jsonb(oldq),(select to_jsonb(x) from private.scheduler_requests x where x.id=oldq.id));
  end if;
  update private.scheduler_requests set status=p_payload->>'decision',version=version+1,decided_by=auth.uid(),decided_at=now(),response=left(coalesce(p_payload->>'response',''),2000) where id=q.id;
  perform private.notify_person(q.person_id,'decision:'||q.id,'Your time-off cancellation was '||lower(p_payload->>'decision')||'.');
  result:='{}';
  perform private.schedule_audit('decide',q.id::text,before_value,(select to_jsonb(x) from private.scheduler_requests x where x.id=q.id));
 else
  result:=private.scheduler_action_v1(p_action,p_payload,p_submission);
 end if;
 if p_action in ('decide','revoke') and q.kind in ('Availability','Time off','Cancel time off') then
  for r in select rev.*,w.week_start from private.schedule_revisions rev join private.schedule_weeks w on w.id=rev.week_id where rev.state in ('Queued','Draft','Attention') and exists(select 1 from jsonb_array_elements(rev.shifts) x where x->>'person_id'=q.person_id) loop
   issues:=private.shift_issues(r.shifts,r.week_start);
   update private.schedule_revisions set error=nullif(array_to_string(issues,E'\n'),''),state=case when cardinality(issues)>0 and r.state='Queued' then 'Attention' else r.state end,version=version+1 where id=r.id;
   if cardinality(issues)>0 and r.state='Queued' then perform private.notify_managers('release-attention:'||r.id||':'||r.version,'Approved restrictions conflict with a queued release. Review and requeue it.');end if;
  end loop;
 end if;
 insert into private.scheduler_submissions(id,actor,action,payload,result) values(p_submission,auth.uid(),p_action,p_payload,result) on conflict do nothing;
 return result;
end $$;
revoke all on function public.workspace_session(),public.workspace_read(date,text),public.scheduler_action(text,jsonb,uuid) from public,anon;
grant execute on function public.workspace_session(),public.workspace_read(date,text),public.scheduler_action(text,jsonb,uuid) to authenticated;
commit;
