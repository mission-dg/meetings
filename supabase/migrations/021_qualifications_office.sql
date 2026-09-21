begin;
alter table public.training_signoffs add column origin text not null default 'training' check(origin in ('training','experience','migration'));
alter table public.manager_profiles add column employment_type text not null default 'Unclassified' check(employment_type in ('Unclassified','Hourly','Salaried'));
alter table public.staff add column version integer not null default 1;
create function private.staff_version() returns trigger language plpgsql set search_path='' as $$begin new.version:=old.version+1;return new;end $$;
create trigger staff_version before update on public.staff for each row execute function private.staff_version();
create table private.qualification_history(id uuid primary key default gen_random_uuid(),staff_id text not null references public.staff(id),job_id uuid not null references public.training_positions(id),actor uuid not null references auth.users(id),action text not null,reason text,at timestamptz not null default now(),batch_id uuid,before_value jsonb,after_value jsonb);
alter table private.qualification_history enable row level security;
revoke all on private.qualification_history from public,anon,authenticated;
create function private.job_qualified(p_staff text,p_job uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.training_signoffs where staff_id=p_staff and training_position_id=p_job and active)$$;
revoke all on function private.job_qualified(text,uuid) from public,anon,authenticated;
create or replace function private.validate_training_progress() returns trigger language plpgsql security definer set search_path='' as $$
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
   if new.origin<>'migration' and not exists(select 1 from public.staff where id=new.staff_id and active) then raise exception 'Choose an active employee';end if;
   if new.origin='training' and not exists(select 1 from public.training_positions where id=new.training_position_id and active and private.training_completed_shifts(new.staff_id,new.training_position_id)>=target_shifts) then raise exception 'Complete the target number of training shifts before signing off';end if;
  end if;
 end if;
 return new;
end $$;

-- All sign-offs now use a permission-checked mutation with audit history.
revoke insert,update on public.training_signoffs from authenticated;
create function public.set_job_qualification(p_staff text,p_job uuid,p_action text,p_reason text,p_version integer,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.scheduler_submissions;f public.training_signoffs;before_value jsonb;payload jsonb:=jsonb_build_object('staff',p_staff,'job',p_job,'action',p_action,'reason',p_reason,'version',p_version);result jsonb;
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.is_manager() then raise exception 'Manager access required';end if;
 if p_action not in ('signoff','override','revoke') or p_action is null then raise exception 'Choose a qualification action';end if;
 if p_action in ('override','revoke') and not (private.is_admin() or private.is_gm()) then raise exception 'GM or IT access required';end if;
 if p_action in ('override','revoke') and length(trim(coalesce(p_reason,'')))=0 then raise exception 'Enter a reason';end if;
 if p_submission is null then raise exception 'Submission required';end if;
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then if prior.actor<>auth.uid() or prior.action<>'qualification' or prior.payload<>payload then raise exception 'Submission changed';end if;return prior.result;end if;
 select * into f from public.training_signoffs where staff_id=p_staff and training_position_id=p_job and active for update;
 if coalesce(f.version,0) is distinct from p_version then raise exception 'Qualification changed. Reload';end if;
 before_value:=case when f.id is null then null else to_jsonb(f) end;
 if p_action='revoke' then
  if f.id is null then raise exception 'No active qualification';end if;
  update public.training_signoffs set active=false where id=f.id returning * into f;
 else
  if f.id is not null then raise exception 'Already qualified';end if;
  if not exists(select 1 from public.training_positions where id=p_job and active) then raise exception 'Choose an active job';end if;
  insert into public.training_signoffs(staff_id,training_position_id,origin) values(p_staff,p_job,case when p_action='override' then 'experience' else 'training' end) returning * into f;
 end if;
 insert into private.qualification_history(staff_id,job_id,actor,action,reason,before_value,after_value) values(p_staff,p_job,auth.uid(),p_action,left(trim(p_reason),2000),before_value,to_jsonb(f));
 perform private.schedule_audit('qualification:'||p_action,f.id::text,before_value,to_jsonb(f)||jsonb_build_object('reason',left(trim(p_reason),2000)));
 result:=to_jsonb(f);insert into private.scheduler_submissions values(p_submission,auth.uid(),'qualification',payload,result);return result;
end $$;
create function private.person_employment(p_person text) returns text language sql stable security definer set search_path='' as $$select coalesce((select employment_type from public.manager_profiles where active and (case when linked_staff_id is null then 'm:'||id::text else 's:'||linked_staff_id end)=p_person),'Hourly')$$;
create function public.set_shl_employment(p_person text,p_type text,p_version integer) returns void language plpgsql security definer set search_path='' as $$
declare m public.manager_profiles;before_value jsonb;
begin
 perform pg_advisory_xact_lock(61902028);
 if not(private.is_admin() or private.is_gm()) then raise exception 'GM or IT access required';end if;
 if p_type is null or p_type not in ('Hourly','Salaried') then raise exception 'Choose Hourly or Salaried';end if;
 select * into m from public.manager_profiles where active and (case when linked_staff_id is null then 'm:'||id::text else 's:'||linked_staff_id end)=p_person for update;
 if m.id is null or m.version is distinct from p_version then raise exception 'Manager changed. Reload';end if;
 before_value:=to_jsonb(m);update public.manager_profiles set employment_type=p_type,version=version+1 where id=m.id;
 perform private.schedule_audit('employment_type',p_person,before_value,jsonb_build_object('employment_type',p_type));
end $$;
create function public.save_employee(p_id text,p_version integer,p_values jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.staff;j public.training_positions;
begin
 perform pg_advisory_xact_lock(61902028);perform pg_advisory_xact_lock(61902026);
 if not private.is_manager() then raise exception 'Manager access required';end if;
 select * into j from public.training_positions where id=(p_values->>'primary_job_id')::uuid and active;
 if j.id is null then raise exception 'Choose an active primary job';end if;
 if p_id is null then
  if not private.is_admin() then raise exception 'IT access required to add employees';end if;
  insert into public.staff(first_name,last_name,department,primary_job_id,active,priority,is_trainer) values(trim(p_values->>'first_name'),trim(p_values->>'last_name'),j.department,j.id,coalesce((p_values->>'active')::boolean,true),coalesce((p_values->>'priority')::boolean,false),coalesce((p_values->>'is_trainer')::boolean,false)) returning * into s;
 else
  select * into s from public.staff where id=p_id for update;
  if s.id is null or s.version is distinct from p_version then raise exception 'Employee changed. Reload';end if;
  if not private.is_admin() and (s.first_name is distinct from p_values->>'first_name' or s.last_name is distinct from p_values->>'last_name' or s.active is distinct from (p_values->>'active')::boolean) then raise exception 'IT manages employee names and access';end if;
  update public.staff set first_name=trim(p_values->>'first_name'),last_name=trim(p_values->>'last_name'),department=j.department,primary_job_id=j.id,active=(p_values->>'active')::boolean,priority=(p_values->>'priority')::boolean,is_trainer=(p_values->>'is_trainer')::boolean where id=p_id returning * into s;
 end if;return to_jsonb(s);
end $$;
revoke all on function public.set_job_qualification(text,uuid,text,text,int,uuid),public.set_shl_employment(text,text,int),public.save_employee(text,int,jsonb),private.person_employment(text),private.staff_version() from public,anon;
grant execute on function public.set_job_qualification(text,uuid,text,text,int,uuid),public.set_shl_employment(text,text,int),public.save_employee(text,int,jsonb) to authenticated;
revoke all on function private.person_employment(text),private.staff_version() from authenticated;
create or replace function public.scheduler_read(p_week date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;w private.schedule_weeks;r private.schedule_revisions;m boolean:=private.is_manager();ca boolean:=private.is_ca();v_staff_id text:=private.employee_staff();my_group text;my_person text:=private.my_person();
begin
 if not private.scheduler_member() then raise exception 'Your account needs active workspace access';end if;
 if extract(dow from p_week)<>0 then raise exception 'Choose a Sunday';end if;
 select * into w from private.schedule_weeks where week_start=p_week;
 if m then select * into r from private.schedule_revisions where id=w.draft_id;end if;
 my_group:=case when m then 'SHL' else (select department from public.staff where id=v_staff_id) end;
 result:=jsonb_build_object(
 'self',jsonb_build_object('id',auth.uid(),'person_id',my_person,'staff_id',v_staff_id,'name',private.account_name(auth.uid()),'is_manager',m,'is_ca',ca,'is_admin',private.is_admin(),'is_gm',private.is_gm()),
 'week',jsonb_build_object('start',p_week,'published_id',w.published_id,'draft',case when m and r.id is not null then to_jsonb(r)||jsonb_build_object('release_name',private.account_name(r.release_by)) else null end),
 'people',coalesce((select jsonb_agg(p order by p->>'name') from (
  select jsonb_build_object('id','s:'||s.id,'staff_id',s.id,'name',s.first_name||' '||s.last_name,'group',case when private.person_is_shl('s:'||s.id) then 'SHL' else s.department end,'primary_job_id',s.primary_job_id,'employment_type',private.person_employment('s:'||s.id),'manager_version',(select version from public.manager_profiles where active and linked_staff_id=s.id),'active',s.active,'is_trainer',s.is_trainer,'on_roster',coalesce((select on_roster from public.manager_profiles where linked_staff_id=s.id and active),true),'is_ca',exists(select 1 from private.employee_accounts a where a.staff_id=s.id and a.active and a.is_ca)) p from public.staff s where s.active or m or ca or exists(select 1 from private.published_shifts() z where z->>'person_id'='s:'||s.id)
  union all select jsonb_build_object('id','m:'||id,'name',name,'group','SHL','employment_type',employment_type,'manager_version',version,'active',active,'on_roster',on_roster,'is_trainer',false,'version',version) from public.manager_profiles mp where linked_staff_id is null and (active or m or exists(select 1 from private.published_shifts() z where z->>'person_id'='m:'||mp.id::text))) q),'[]'),
 'published',coalesce((select jsonb_agg(jsonb_build_object('week',wk.week_start,'revision_id',rr.id,'shifts',case when m then rr.shifts else (select coalesce(jsonb_agg(s-'qualification_reason'),'[]') from jsonb_array_elements(rr.shifts) s) end)) from private.schedule_weeks wk join private.schedule_revisions rr on rr.id=wk.published_id),'[]'),
 'jobs',coalesce((select jsonb_agg(to_jsonb(j)) from public.training_positions j),'[]'),
 'training',coalesce((select jsonb_agg(to_jsonb(t)) from public.training_sessions t where m or private.training_visible(t.schedule_revision_id) and (ca or t.staff_id=v_staff_id or t.trainer_id=v_staff_id)),'[]'),
 'signoffs',coalesce((select jsonb_agg(to_jsonb(f)) from public.training_signoffs f where m or ca or f.staff_id=v_staff_id),'[]'),
 'appointments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'scheduled_at',a.scheduled_at,'status',a.status,'type',a.type,'manager',p.name,'employee',s.first_name||' '||s.last_name)) from public.meetings a join public.manager_profiles p on p.id=a.manager_id join public.staff s on s.id=a.staff_id where a.staff_id=v_staff_id or a.manager_id=auth.uid()),'[]'),
 'requests',coalesce((select jsonb_agg(case when m or q.created_by=auth.uid() then to_jsonb(q)||jsonb_build_object('decided_name',case when q.decided_by is not null then private.account_name(q.decided_by) end) else to_jsonb(q)-'reason'-'response' end order by q.created_at desc) from private.scheduler_requests q where m or q.created_by=auth.uid() or q.claimed_by=auth.uid() or q.payload->>'recipient'=my_person or q.kind='Offer' and q.status='Pending'),'[]'),
 'announcements',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('author',private.account_name(a.created_by),'read',coalesce(rd.version=a.version,false)) order by a.created_at desc) from private.announcements a left join private.announcement_reads rd on rd.announcement_id=a.id and rd.user_id=auth.uid() where (a.active or a.created_by=auth.uid()) and (cardinality(a.groups)=0 or my_group=any(a.groups) or a.created_by=auth.uid())),'[]'),
 'announcement_history',coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'announcement_id',h.record_id,'at',h.changed_at,'value',h.after_value) order by h.id desc) from private.scheduler_audit h join private.announcements a on a.id::text=h.record_id where h.action='announcement' and a.created_by=auth.uid()),'[]'),
 'notifications',coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (select * from private.scheduler_notifications where user_id=auth.uid() order by created_at desc limit 100) n),'[]'),
 'accounts',case when m then coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('role',case when mp.active and mp.is_admin then 'it' when mp.active then 'manager' when a.is_ca then 'ca' else 'employee' end,'manager_version',mp.version)) from private.employee_accounts a left join public.manager_profiles mp on mp.id=a.id),'[]') else '[]'::jsonb end,
 'service',case when m then (select to_jsonb(s) from private.scheduler_settings s) else '{}'::jsonb end,
 'releases',case when m then coalesce((select jsonb_agg(jsonb_build_object('id',rev.id,'week',wk.week_start,'state',rev.state,'release_at',rev.release_at,'error',rev.error,'release_name',private.account_name(rev.release_by))) from private.schedule_revisions rev join private.schedule_weeks wk on wk.id=rev.week_id where rev.state in ('Queued','Attention')),'[]') else '[]'::jsonb end,
 'audit',case when m then coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('actor_name',private.account_name(a.actor))) from (select * from private.scheduler_audit order by id desc limit 100) a),'[]') else '[]'::jsonb end);
 return result;
end $$;
create or replace function private.shift_issues(p_shifts jsonb,p_week date) returns text[] language plpgsql stable security definer set search_path='' as $$
declare issues text[]:='{}';s jsonb;o jsonb;t record;p text;starts timestamptz;ends timestamptz;job uuid;why text;seen text[]:='{}';
begin
 if jsonb_typeof(p_shifts) is distinct from 'array' or jsonb_array_length(p_shifts)>1000 then return array['A schedule must contain at most 1,000 shifts'];end if;
 for s in select value from jsonb_array_elements(p_shifts) loop
  begin
   perform (s->>'id')::uuid;p:=s->>'person_id';starts:=(s->>'start')::timestamptz;ends:=(s->>'end')::timestamptz;job:=(s->>'job_id')::uuid;
   if s->>'id' is null or p is null or starts is null or ends is null or (s->>'slot')::int<1 or s->>'slot' is null then raise exception 'Missing shift fields';end if;
   if s->>'id'=any(seen) then raise exception 'Duplicate shift ID';end if;seen:=array_append(seen,s->>'id');
   if ends<=starts or ends-starts>interval '12 hours' then raise exception 'Shift end must be after start and no more than 12 hours later';end if;
   if (starts at time zone 'America/Chicago')::date<p_week or (starts at time zone 'America/Chicago')::date>=p_week+7 then raise exception 'Shift must start in this scheduling week';end if;
   if exists(select 1 from private.schedule_weeks ww join private.schedule_revisions rr on rr.id=ww.published_id cross join lateral jsonb_array_elements(rr.shifts) xx where ww.week_start<>p_week and xx->>'id'=s->>'id') then raise exception 'Shift ID is already used in another week';end if;
   if not private.person_active(p) then raise exception 'Choose an active person on the work roster';end if;
   if coalesce(s->>'assignment_type','regular') not in ('regular','opening_office','closing_office') then raise exception 'Choose a valid assignment type';end if;
   if coalesce(s->>'assignment_type','regular')<>'regular' then
    if not private.person_is_shl(p) then raise exception 'Office assignments require an SHL';end if;
    if private.person_employment(p)='Unclassified' then raise exception 'GM or IT must classify this SHL as Hourly or Salaried first';end if;
    if job is not null then raise exception 'Office assignments cannot also have a regular job';end if;
   elsif job is null then
    if not private.person_is_shl(p) then raise exception 'Choose an active job';end if;
   elsif not exists(select 1 from public.training_positions where id=job and active) then raise exception 'Choose an active job';end if;
   why:=private.person_conflict(p,starts,ends);if why is not null then raise exception '%',why;end if;
   if exists(select 1 from jsonb_array_elements(p_shifts) x where x->>'id'<>s->>'id' and x->>'person_id'=p and (x->>'start')::timestamptz<ends and (x->>'end')::timestamptz>starts) then raise exception 'Overlapping work shifts';end if;
   if exists(select 1 from private.schedule_weeks w join private.schedule_revisions r on r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) x where w.week_start<>p_week and x->>'person_id'=p and (x->>'start')::timestamptz<ends and (x->>'end')::timestamptz>starts) then raise exception 'Overlap with another published week';end if;
  exception when others then issues:=array_append(issues,private.person_name(s->>'person_id')||': '||sqlerrm);end;
 end loop;return issues;
end $$;
create function private.office_assignment_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare s jsonb;k text;
begin
 if TG_OP='UPDATE' and new.shifts is not distinct from old.shifts then return new;end if;
 for s in select value from jsonb_array_elements(new.shifts) loop
  k:=coalesce(s->>'assignment_type','regular');
  if k not in ('regular','opening_office','closing_office') then raise exception 'Choose a valid assignment type';end if;
  if k<>'regular' and (not private.person_is_shl(s->>'person_id') or private.person_employment(s->>'person_id')='Unclassified' or s->>'job_id' is not null) then raise exception 'Office assignments require a classified SHL and no regular job';end if;
 end loop;return new;
end $$;
revoke all on function private.office_assignment_guard() from public,anon,authenticated;
create trigger office_assignment_guard before insert or update of shifts on private.schedule_revisions for each row execute function private.office_assignment_guard();
create or replace function public.calendar_feed_data(p_token text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid;s text;linked text;m boolean;p text;events jsonb;lo timestamptz:=now()-interval '90 days';hi timestamptz:=now()+interval '18 months';
begin
 if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return null;end if;
 select user_id into u from private.calendar_tokens where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if u is null then return null;end if;
 select exists(select 1 from public.manager_profiles where id=u and active) into m;
 select a.staff_id into s from private.employee_accounts a join public.staff st on st.id=a.staff_id where a.id=u and a.active and st.active;
 if not m and s is null then return null;end if;
 select linked_staff_id into linked from public.manager_profiles where id=u and active;
 p:=case when m then case when linked is null then 'm:'||u::text else 's:'||linked end else 's:'||s end;
 select coalesce(jsonb_agg(e),'[]') into events from (
  select jsonb_build_object('uid','shift-'||(x->>'id'),'start',x->>'start','end',x->>'end','title',case x->>'assignment_type' when 'opening_office' then 'Opening office' when 'closing_office' then 'Closing office' else 'Work · '||coalesce(j.name,'SHL') end,'status','CONFIRMED','sequence',(select count(*) from private.schedule_revisions z where z.week_id=w.id and z.state='Published'),'updated',r.released_at) e
  from private.schedule_weeks w join private.schedule_revisions r on r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) x left join public.training_positions j on j.id=(x->>'job_id')::uuid
  where x->>'person_id'=p and (x->>'end')::timestamptz>=lo and (x->>'start')::timestamptz<hi
  union all
  select jsonb_build_object('uid','meeting-'||a.id,'start',a.scheduled_at,'title',a.type||' meeting · '||private.person_name('s:'||a.staff_id),'status',case when a.status in ('Cancelled','Missed') then 'CANCELLED' else 'CONFIRMED' end,'sequence',a.version,'updated',a.updated_at)
  from public.meetings a where (a.staff_id=s or a.manager_id=u) and a.scheduled_at>=lo and a.scheduled_at<hi
  union all
  select jsonb_build_object('uid','training-'||t.id,'start',t.scheduled_at,'end',t.ends_at,'title',private.person_name('s:'||t.trainer_id)||' Training '||private.person_name('s:'||t.staff_id),'status',case when t.status in ('Cancelled','Missed') then 'CANCELLED' else 'CONFIRMED' end,'sequence',t.version,'updated',t.updated_at)
  from public.training_sessions t where (t.staff_id=s or t.trainer_id=s) and private.training_visible(t.schedule_revision_id) and t.scheduled_at>=lo and t.scheduled_at<hi
  union all
  select distinct on (old->>'id') jsonb_build_object('uid','shift-'||(old->>'id'),'start',old->>'start','end',old->>'end','title','Cancelled work shift','status','CANCELLED','sequence',(select count(*) from private.schedule_revisions z where z.week_id=w.id and z.state='Published'),'updated',current_r.released_at)
  from private.schedule_weeks w join private.schedule_revisions r on r.week_id=w.id and r.state='Published' join private.schedule_revisions current_r on current_r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) old
  where old->>'person_id'=p and (old->>'end')::timestamptz>=lo and (old->>'start')::timestamptz<hi and not exists(select 1 from jsonb_array_elements(current_r.shifts) x where x->>'id'=old->>'id' and x->>'person_id'=p)
 ) q;
 return jsonb_build_object('events',events);
end $$;
create or replace function public.workspace_read(p_week date,p_view text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb; me text:=private.my_person(); sid text:=private.employee_staff(); ca boolean:=private.is_ca(); g text;
begin
 if p_view not in ('employee','manager','it') or p_view is null then raise exception 'Choose an available workspace';end if;
 if p_view='it' and not private.is_admin() or p_view='manager' and not private.is_manager() then raise exception 'This workspace is not available to your account';end if;
 r:=public.scheduler_read(p_week);
 r:=r||jsonb_build_object('workspace',p_view,'available_views',public.workspace_session()->'views');
 if p_view='employee' then
  r:=jsonb_set(r,'{self}',(r->'self')||jsonb_build_object('is_manager',false,'is_admin',false,'is_gm',false));
  r:=jsonb_set(r,'{week,draft}','null');
  r:=r||jsonb_build_object('accounts','[]'::jsonb,'service','{}'::jsonb,'audit','[]'::jsonb,'releases','[]'::jsonb);
  r:=jsonb_set(r,'{published}',coalesce((select jsonb_agg(w||jsonb_build_object('shifts',(select coalesce(jsonb_agg(s-'qualification_reason'),'[]') from jsonb_array_elements(w->'shifts') s))) from jsonb_array_elements(r->'published') w),'[]'));
  r:=jsonb_set(r,'{training}',coalesce((select jsonb_agg(t) from jsonb_array_elements(r->'training') t where private.training_visible((t->>'schedule_revision_id')::uuid) and (ca or t->>'staff_id'=sid or t->>'trainer_id'=sid)),'[]'));
  r:=jsonb_set(r,'{signoffs}',coalesce((select jsonb_agg(f) from jsonb_array_elements(r->'signoffs') f where ca or f->>'staff_id'=sid),'[]'));
  r:=jsonb_set(r,'{requests}',coalesce((select jsonb_agg(case when q->>'created_by'=auth.uid()::text then q else q-'reason'-'response' end) from jsonb_array_elements(r->'requests') q where q->>'created_by'=auth.uid()::text or q->>'claimed_by'=auth.uid()::text or q->'payload'->>'recipient'=me or q->>'kind'='Offer' and q->>'status'='Pending'),'[]'));
  -- Manager notifications are not employee-facing merely because the account has both roles.
  r:=jsonb_set(r,'{notifications}',coalesce((select jsonb_agg(n) from jsonb_array_elements(r->'notifications') n where n->>'event_key' ~ '^(schedule:|decision:|revoke:|accepted:|invalid:)' or exists(select 1 from private.scheduler_requests q where n->>'event_key'='request:'||q.id and q.kind in ('Trade','Coverage') and q.payload->>'recipient'=me)),'[]'));
  r:=jsonb_set(r,'{people}',coalesce((select jsonb_agg(p-'version'-'manager_version') from jsonb_array_elements(r->'people') p where (p->>'active')::boolean or p->>'id'=me or exists(select 1 from private.published_shifts() s where s->>'person_id'=p->>'id')),'[]'));
 end if;
 return r;
end $$;
commit;
