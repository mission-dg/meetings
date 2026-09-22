begin;
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
   if coalesce(s->>'assignment_type','regular') not in ('regular','opening_office','closing_office','training') then raise exception 'Choose a valid assignment type';end if;
   if s->>'assignment_type'='training' then
    if job is not null or nullif(btrim(s->>'activity_title'),'') is null or length(s->>'activity_title')>120 then raise exception 'Training requires an activity title and no position job';end if;
   elsif coalesce(s->>'assignment_type','regular')<>'regular' then
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
create or replace function private.office_assignment_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare s jsonb;k text;
begin
 if TG_OP='UPDATE' and new.shifts is not distinct from old.shifts then return new;end if;
 for s in select value from jsonb_array_elements(new.shifts) loop
  k:=coalesce(s->>'assignment_type','regular');
  if k not in ('regular','opening_office','closing_office','training') then raise exception 'Choose a valid assignment type';end if;
  if k='training' and (s->>'job_id' is not null or nullif(btrim(s->>'activity_title'),'') is null or length(s->>'activity_title')>120) then raise exception 'Training requires an activity title and no position job';end if;
  if k in ('opening_office','closing_office') and (not private.person_is_shl(s->>'person_id') or private.person_employment(s->>'person_id')='Unclassified' or s->>'job_id' is not null) then raise exception 'Office assignments require a classified SHL and no regular job';end if;
 end loop;return new;
end $$;
revoke all on function private.office_assignment_guard() from public,anon,authenticated;

alter table public.meetings add column timing_mode text not null default 'exact' check(timing_mode in ('exact','during_shift')),
 add column work_shift_id uuid,add column manager_shift_id uuid,add column schedule_revision_id uuid references private.schedule_revisions(id);
alter table public.meetings add constraint shift_meeting_links check((timing_mode='exact' and work_shift_id is null and manager_shift_id is null and schedule_revision_id is null) or (timing_mode='during_shift' and work_shift_id is not null and manager_shift_id is not null));
create function private.manager_person(p_manager uuid) returns text language sql stable security definer set search_path='' as $$
 select case when linked_staff_id is null then 'm:'||id::text else 's:'||linked_staff_id end from public.manager_profiles where id=p_manager and active
$$;
create function private.meeting_shift(p_id uuid,p_revision uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select s from private.schedule_revisions r cross join lateral jsonb_array_elements(r.shifts) s
 where s->>'id'=p_id::text and (r.id=p_revision and r.state in ('Draft','Attention','Queued') or exists(select 1 from private.schedule_weeks where published_id=r.id) and (p_revision is null or exists(select 1 from private.schedule_revisions target where target.id=p_revision and (target.state='Published' or target.week_id<>r.week_id)))) order by (r.id=p_revision) desc nulls last limit 1
$$;
create function private.meeting_link_error(m public.meetings,e jsonb,g jsonb) returns text language plpgsql stable security definer set search_path='' as $$
begin
 if e is null or g is null then return 'The employee and manager need scheduled work shifts';end if;
 if e->>'person_id'<>'s:'||m.staff_id or g->>'person_id' is distinct from private.manager_person(m.manager_id) then return 'Meeting participants no longer match their assigned shifts';end if;
 if not private.person_active(e->>'person_id') or not private.person_active(g->>'person_id') then return 'Meeting participants must be active on the roster';end if;
 if e->>'assignment_type'='training' or g->>'assignment_type'='training' then return 'Attach check-ins to working time, not a dedicated Training block';end if;
 if greatest((e->>'start')::timestamptz,(g->>'start')::timestamptz)>=least((e->>'end')::timestamptz,(g->>'end')::timestamptz) then return 'The employee and manager shifts must overlap';end if;
 return null;
end $$;
create function private.meeting_issues(p_shifts jsonb,p_week date,p_revision uuid) returns text[] language plpgsql stable security definer set search_path='' as $$
declare m public.meetings;e jsonb;g jsonb;why text;issues text[]:='{}';
begin
 for m in select * from public.meetings where timing_mode='during_shift' and status='Scheduled' and (schedule_revision_id=p_revision or private.training_visible(schedule_revision_id)) loop
  e:=private.meeting_shift(m.work_shift_id,m.schedule_revision_id);g:=private.meeting_shift(m.manager_shift_id,m.schedule_revision_id);
  if m.schedule_revision_id is distinct from p_revision and not exists(select 1 from jsonb_array_elements(p_shifts) x where x->>'id' in (m.work_shift_id::text,m.manager_shift_id::text)) and coalesce(((e->>'start')::timestamptz at time zone 'America/Chicago')::date not between p_week and p_week+6,true) and coalesce(((g->>'start')::timestamptz at time zone 'America/Chicago')::date not between p_week and p_week+6,true) then continue;end if;
  if (e->>'start')::timestamptz at time zone 'America/Chicago' >=p_week and (e->>'start')::timestamptz at time zone 'America/Chicago' <p_week+7 or exists(select 1 from jsonb_array_elements(p_shifts) s where s->>'id'=m.work_shift_id::text) then select s into e from jsonb_array_elements(p_shifts) s where s->>'id'=m.work_shift_id::text;end if;
  if (g->>'start')::timestamptz at time zone 'America/Chicago' >=p_week and (g->>'start')::timestamptz at time zone 'America/Chicago' <p_week+7 or exists(select 1 from jsonb_array_elements(p_shifts) s where s->>'id'=m.manager_shift_id::text) then select s into g from jsonb_array_elements(p_shifts) s where s->>'id'=m.manager_shift_id::text;end if;
  why:=private.meeting_link_error(m,e,g);
  if why is not null then issues:=array_append(issues,private.person_name('s:'||m.staff_id)||' meeting: '||why||'. Its creator must reschedule or cancel it.');end if;
 end loop;return issues;
end $$;
-- Existing release/queue/worker checks already call training_issues; extend that
-- validation boundary to include check-ins without introducing a second worker.
alter function private.training_issues(jsonb,date,uuid) rename to training_issues_before_meetings;
create function private.training_issues(p_shifts jsonb,p_week date,p_revision uuid) returns text[] language sql stable security definer set search_path='' as $$
 select private.training_issues_before_meetings(p_shifts,p_week,p_revision)||private.meeting_issues(p_shifts,p_week,p_revision)
$$;
create function private.guard_shift_meetings() returns trigger language plpgsql security definer set search_path='' as $$
declare issues text[];wk date;
begin
 perform pg_advisory_xact_lock(61902028);
 if TG_OP='UPDATE' and new.shifts is not distinct from old.shifts then return new;end if;
 select week_start into wk from private.schedule_weeks where id=new.week_id;
 issues:=private.meeting_issues(new.shifts,wk,new.id);
 if cardinality(issues)>0 then raise exception '%',array_to_string(issues,E'\n');end if;
 return new;
end $$;
create trigger guard_shift_meetings before insert or update of shifts on private.schedule_revisions for each row execute function private.guard_shift_meetings();
create function private.validate_shift_meeting() returns trigger language plpgsql security definer set search_path='' as $$
declare e jsonb;g jsonb;why text;
begin
 perform pg_advisory_xact_lock(61902028);
 if TG_OP='UPDATE' and old.timing_mode='during_shift' and new.timing_mode<>'during_shift' then raise exception 'Reschedule the linked meeting to another shift, or cancel it';end if;
 if new.timing_mode<>'during_shift' then return new;end if;
 if TG_OP='UPDATE' and private.training_visible(old.schedule_revision_id) and not private.training_visible(new.schedule_revision_id) then raise exception 'Release the shifts before moving an existing published booking';end if;
 if exists(select 1 from private.schedule_revisions r where r.state='Queued' and (r.id=new.schedule_revision_id or exists(select 1 from jsonb_array_elements(r.shifts) s where s->>'id' in (new.work_shift_id::text,new.manager_shift_id::text)))) or TG_OP='UPDATE' and exists(select 1 from private.schedule_revisions r where r.state='Queued' and (r.id=old.schedule_revision_id or exists(select 1 from jsonb_array_elements(r.shifts) s where s->>'id' in (old.work_shift_id::text,old.manager_shift_id::text)))) then raise exception 'Cancel the queued release before changing this meeting';end if;
 if new.status='Scheduled' then
  e:=private.meeting_shift(new.work_shift_id,new.schedule_revision_id);g:=private.meeting_shift(new.manager_shift_id,new.schedule_revision_id);
  why:=private.meeting_link_error(new,e,g);if why is not null then raise exception '%',why;end if;
  if (TG_OP='INSERT' or new.work_shift_id is distinct from old.work_shift_id or new.manager_shift_id is distinct from old.manager_shift_id) and least((e->>'end')::timestamptz,(g->>'end')::timestamptz)<=now() then raise exception 'Choose shifts with working time remaining';end if;
 end if;
 if new.status='Completed' and not private.training_visible(new.schedule_revision_id) then raise exception 'Release the schedule before completing its meeting';end if;
 return new;
end $$;
create trigger a_shift_meeting_validation before insert or update on public.meetings for each row execute function private.validate_shift_meeting();
create function private.shift_meeting_effects() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.timing_mode='during_shift' then
  update private.schedule_revisions set version=version+1 where id in (new.schedule_revision_id,case when TG_OP='UPDATE' then old.schedule_revision_id end) and state in ('Draft','Attention');
  if private.training_visible(new.schedule_revision_id) then perform private.notify_person('s:'||new.staff_id,'schedule:meeting:'||new.id||':'||new.version,'Your shift check-in was updated. Check My Schedule.');end if;
 end if;return new;
end $$;
create trigger shift_meeting_effects after insert or update on public.meetings for each row execute function private.shift_meeting_effects();
create function public.save_shift_meeting(p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.scheduler_submissions;m public.meetings;r private.schedule_revisions;w private.schedule_weeks;es jsonb;gs jsonb;rev uuid;req uuid;result jsonb;
begin
 if not private.is_manager() then raise exception 'Active manager access required';end if;
 if p_submission is null then raise exception 'Submission ID required';end if;
 perform pg_advisory_xact_lock(61902028);
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then if prior.actor<>auth.uid() or prior.action<>'shift_meeting' or prior.payload<>p_payload then raise exception 'Submission already used';end if;return prior.result;end if;
 if p_payload->>'id' is not null then
  select * into m from public.meetings where id=(p_payload->>'id')::uuid for update;
  if m.id is null or m.created_by<>auth.uid() then raise exception 'Only the meeting creator can edit it';end if;
  if m.version is distinct from (p_payload->>'version')::int then raise exception 'Meeting changed. Reload';end if;
  if m.status<>'Scheduled' then raise exception 'Only open meetings can be scheduled on shifts';end if;
 end if;
 rev:=(p_payload->>'revision_id')::uuid;
 select * into r from private.schedule_revisions where id=rev for update;
 select * into w from private.schedule_weeks where id=r.week_id;
 if r.id is null or r.version is distinct from (p_payload->>'revision_version')::int or (w.draft_id is distinct from r.id and w.published_id is distinct from r.id) then raise exception 'Schedule changed. Reload';end if;
 if r.state='Queued' then raise exception 'Cancel the queued release before changing this meeting';end if;
 select s into es from jsonb_array_elements(r.shifts) s where s->>'id'=p_payload->>'work_shift_id';
 gs:=private.meeting_shift((p_payload->>'manager_shift_id')::uuid,r.id);
 if m.id is not null and r.state<>'Published' and private.training_visible(m.schedule_revision_id) then raise exception 'Release the shifts first, then link or reschedule this existing published booking';end if;
 if es is null or gs is null then raise exception 'Choose employee and manager shifts from this schedule';end if;
 if m.id is not null and 's:'||m.staff_id<>es->>'person_id' then raise exception 'Preserve the existing meeting employee';end if;
 if m.id is null then
  insert into public.meetings(staff_id,manager_id,type,scheduled_at,timing_mode,work_shift_id,manager_shift_id,schedule_revision_id,created_by)
  values(substring(es->>'person_id' from 3),(p_payload->>'manager_id')::uuid,p_payload->>'type',(es->>'start')::timestamptz,'during_shift',(es->>'id')::uuid,(gs->>'id')::uuid,case when r.state='Published' then null else rev end,auth.uid()) returning * into m;
 else
  update public.meetings set manager_id=(p_payload->>'manager_id')::uuid,type=p_payload->>'type',timing_mode='during_shift',work_shift_id=(es->>'id')::uuid,manager_shift_id=(gs->>'id')::uuid,schedule_revision_id=case when r.state='Published' then null else rev end where id=m.id returning * into m;
 end if;
 req:=(p_payload->>'request_id')::uuid;
 if req is not null then
  update public.gm_requests set meeting_id=m.id where id=req and staff_id=m.staff_id and status='Open' and (meeting_id is null or meeting_id=m.id);
  if not found then raise exception 'GM request changed. Reload';end if;
 end if;
 result:=to_jsonb(m);
 insert into private.scheduler_submissions values(p_submission,auth.uid(),'shift_meeting',p_payload,result);
 return result;
end $$;
-- Keep the existing ownership, outcome, special-meeting and request validations.
create or replace function private.validate_meeting() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='UPDATE' then
  if new.id<>old.id or new.created_by<>old.created_by or new.created_at<>old.created_at then raise exception 'Meeting ownership cannot change';end if;
  if new.version<>old.version then raise exception 'Reload this meeting before editing';end if;
  new.version:=old.version+1;
 end if;
 if new.status='Scheduled' and (not exists(select 1 from public.staff where id=new.staff_id and active) or not exists(select 1 from public.manager_profiles where id=new.manager_id and active)) then raise exception 'Open bookings require active staff and managers';end if;
 if new.timing_mode='exact' and new.status='Scheduled' and (TG_OP='INSERT' or new.scheduled_at is distinct from old.scheduled_at) and new.scheduled_at<now() then raise exception 'Choose a future meeting time';end if;
 if new.completed_on>(now() at time zone 'America/Chicago')::date then raise exception 'Completion date cannot be in the future';end if;
 if new.type='Special' and (TG_OP='INSERT' or new.type is distinct from old.type or new.manager_id is distinct from old.manager_id) then
  if not private.is_gm() or not exists(select 1 from public.manager_profiles where id=new.manager_id and active and is_gm) then raise exception 'Only the GM can create special meetings';end if;
 end if;
 if exists(select 1 from public.gm_requests where meeting_id=new.id and (staff_id<>new.staff_id or not exists(select 1 from public.manager_profiles where id=new.manager_id and is_gm and active))) then raise exception 'A linked GM meeting must retain its employee and active GM';end if;
 new.updated_at:=now();return new;
end $$;
alter function public.scheduler_read(date) rename to scheduler_read_before_shift_meetings;
revoke all on function public.scheduler_read_before_shift_meetings(date) from public,anon,authenticated;
create function public.scheduler_read(p_week date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;manager boolean:=private.is_manager();staff text:=private.employee_staff();pool jsonb;
begin
 r:=public.scheduler_read_before_shift_meetings(p_week);
 r:=jsonb_set(r,'{published}',coalesce((select jsonb_agg(v||jsonb_build_object('version',(select version from private.schedule_revisions where id=(v->>'revision_id')::uuid))) from jsonb_array_elements(r->'published') v),'[]'));
 r:=r||jsonb_build_object('shift_meetings',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'staff_id',m.staff_id,'manager_id',m.manager_id,'manager',mp.name,'employee',st.first_name||' '||st.last_name,'type',m.type,'status',m.status,'version',m.version,'created_by',m.created_by,'work_shift_id',m.work_shift_id,'manager_shift_id',m.manager_shift_id,'schedule_revision_id',m.schedule_revision_id,'timing_mode',m.timing_mode,'scheduled_at',m.scheduled_at,'completed_on',m.completed_on)) from public.meetings m join public.manager_profiles mp on mp.id=m.manager_id join public.staff st on st.id=m.staff_id where manager or m.timing_mode='during_shift' and m.staff_id=staff and private.training_visible(m.schedule_revision_id)),'[]'));
 r:=jsonb_set(r,'{appointments}',coalesce((select jsonb_agg(a) from jsonb_array_elements(r->'appointments') a where exists(select 1 from public.meetings m where m.id=(a->>'id')::uuid and m.timing_mode='exact')),'[]'));
 if manager then
  r:=r||jsonb_build_object('meeting_managers',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'person_id',private.manager_person(id),'is_gm',is_gm)),'[]') from public.manager_profiles where active), 'meeting_requests',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'staff_id',staff_id,'meeting_id',meeting_id)),'[]') from public.gm_requests where status='Open'));
  pool:=coalesce(r->'week'->'draft'->'shifts',(select v->'shifts' from jsonb_array_elements(r->'published') v where v->>'week'=p_week::text),'[]');
  r:=r||jsonb_build_object('meeting_due',coalesce((select jsonb_agg(jsonb_build_object('staff_id',st.id,'shift_id',next_shift.s->>'id')) from public.staff st cross join lateral(select x s from jsonb_array_elements(pool) x where x->>'person_id'='s:'||st.id and (x->>'end')::timestamptz>now() and coalesce(x->>'assignment_type','regular')='regular' order by (x->>'start')::timestamptz,x->>'id' limit 1) next_shift where st.active and not exists(select 1 from public.manager_profiles where active and linked_staff_id=st.id) and not exists(select 1 from public.meetings where staff_id=st.id and status='Scheduled') and not exists(select 1 from public.meetings where staff_id=st.id and status='Completed' and completed_on is not null and (completed_on+interval '6 months')::date>(now() at time zone 'America/Chicago')::date)),'[]'));
 else r:=r||jsonb_build_object('meeting_due','[]'::jsonb,'meeting_managers','[]'::jsonb,'meeting_requests','[]'::jsonb);end if;
 return r;
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
  r:=jsonb_set(r,'{appointments}',coalesce((select jsonb_agg(a) from jsonb_array_elements(r->'appointments') a where exists(select 1 from public.meetings m where m.id=(a->>'id')::uuid and m.staff_id=sid)),'[]'));
  r:=r||jsonb_build_object('meeting_due','[]'::jsonb,'meeting_managers','[]'::jsonb,'meeting_requests','[]'::jsonb);
  r:=jsonb_set(r,'{shift_meetings}',coalesce((select jsonb_agg(m) from jsonb_array_elements(r->'shift_meetings') m where m->>'staff_id'=sid and m->>'timing_mode'='during_shift' and private.training_visible((m->>'schedule_revision_id')::uuid)),'[]'));
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
  select jsonb_build_object('uid','shift-'||(x->>'id'),'start',x->>'start','end',x->>'end','title',case x->>'assignment_type' when 'training' then 'Training · '||(x->>'activity_title') when 'opening_office' then 'Opening office' when 'closing_office' then 'Closing office' else 'Work · '||coalesce(j.name,'SHL') end||coalesce((select ' · Meeting with '||string_agg(mp.name,', ')||' during this shift' from public.meetings m join public.manager_profiles mp on mp.id=m.manager_id where m.work_shift_id::text=x->>'id' and m.staff_id=s and m.status='Scheduled' and m.timing_mode='during_shift' and private.training_visible(m.schedule_revision_id)),''),'status','CONFIRMED','sequence',(select count(*) from private.schedule_revisions z where z.week_id=w.id and z.state='Published')+coalesce((select sum(m.version) from public.meetings m where m.work_shift_id::text=x->>'id' and m.staff_id=s and private.training_visible(m.schedule_revision_id)),0),'updated',greatest(r.released_at,(select max(m.updated_at) from public.meetings m where m.work_shift_id::text=x->>'id' and m.staff_id=s and private.training_visible(m.schedule_revision_id)))) e
  from private.schedule_weeks w join private.schedule_revisions r on r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) x left join public.training_positions j on j.id=(x->>'job_id')::uuid
  where x->>'person_id'=p and (x->>'end')::timestamptz>=lo and (x->>'start')::timestamptz<hi
  union all
  select jsonb_build_object('uid','meeting-'||a.id,'start',a.scheduled_at,'title',a.type||' meeting · '||private.person_name('s:'||a.staff_id),'status',case when a.status in ('Cancelled','Missed') then 'CANCELLED' else 'CONFIRMED' end,'sequence',a.version,'updated',a.updated_at)
  from public.meetings a where a.timing_mode='exact' and (a.staff_id=s or a.manager_id=u) and a.scheduled_at>=lo and a.scheduled_at<hi
  union all
  select jsonb_build_object('uid','meeting-'||a.id,'start',a.scheduled_at,'title','Meeting moved to work shift','status','CANCELLED','sequence',a.version,'updated',a.updated_at)
  from public.meetings a where a.timing_mode='during_shift' and (a.staff_id=s or a.manager_id=u) and a.scheduled_at>=lo and a.scheduled_at<hi
   and exists(select 1 from public.change_history h where h.table_name='meetings' and h.record_id=a.id::text and h.before_value->>'timing_mode'='exact')
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

revoke all on function private.manager_person(uuid),private.meeting_shift(uuid,uuid),private.meeting_link_error(public.meetings,jsonb,jsonb),private.meeting_issues(jsonb,date,uuid),private.training_issues_before_meetings(jsonb,date,uuid),private.training_issues(jsonb,date,uuid),private.guard_shift_meetings(),private.validate_shift_meeting(),private.shift_meeting_effects() from public,anon,authenticated;
revoke all on function public.scheduler_read(date),public.save_shift_meeting(jsonb,uuid) from public,anon;
grant execute on function public.scheduler_read(date),public.save_shift_meeting(jsonb,uuid) to authenticated;
commit;
