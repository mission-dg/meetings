begin;
create table private.staff_meetings(id uuid primary key default gen_random_uuid(),title text not null,starts_at timestamptz not null,ends_at timestamptz not null,mode text not null check(mode in ('separate','within')),week date not null,people text[] not null,originals jsonb not null default '[]',generated jsonb not null default '[]',cancelled boolean not null default false,created_by uuid not null references auth.users(id),version int not null default 1);
alter table private.staff_meetings enable row level security;
revoke all on private.staff_meetings from public,anon,authenticated;
create function public.staff_meetings_read(p_employee boolean default false) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.scheduler_member() then raise exception 'Active access required';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'title',coalesce(pub.title,m.title),'start',m.starts_at,'end',m.ends_at,'mode',m.mode,'week',m.week,'version',m.version,'created_by',case when not p_employee and private.is_manager() then m.created_by end,'status',case when (p_employee or not private.is_manager()) and pub.n>0 then 'Published' when m.cancelled and pub.n>0 then 'Cancellation pending release' when m.cancelled then 'Cancelled' when pub.n>0 then 'Published' else 'Draft' end,'attendees',case when not p_employee and private.is_manager() then (select jsonb_agg(jsonb_build_object('id',p,'name',private.person_name(p))) from unnest(m.people) p) end) order by m.starts_at),'[]') into result
 from private.staff_meetings m cross join lateral(select count(*) n,min(s->>'activity_title') title from private.published_shifts() s where exists(select 1 from jsonb_array_elements(m.generated) g where g->>'id'=s->>'id' and g->>'assignment_type'='training') and (not p_employee and private.is_manager() or s->>'person_id'=private.my_person())) pub
 where not p_employee and private.is_manager() or private.my_person()=any(m.people) and pub.n>0;
 return jsonb_build_object('meetings',result);
end $$;
create function public.staff_meeting_save(p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.scheduler_submissions;m private.staff_meetings;w private.schedule_weeks;r private.schedule_revisions;v date;lo timestamptz;hi timestamptz;p text;source jsonb;piece jsonb;items jsonb;originals jsonb:='[]';generated jsonb:='[]';people text[];issues text[];result jsonb;v_id uuid:=coalesce((p_payload->>'id')::uuid,gen_random_uuid());
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.is_manager() then raise exception 'Scheduling manager access required';end if;
 if p_submission is null then raise exception 'Submission required';end if;
 select * into prior from private.scheduler_submissions where private.scheduler_submissions.id=p_submission;
 if found then if prior.actor<>auth.uid() or prior.action<>'staff_meeting' or prior.payload<>p_payload then raise exception 'Submission changed';end if;return prior.result;end if;
 if p_payload->>'action'='cancel' then
  select * into m from private.staff_meetings where staff_meetings.id=v_id for update;
  if m.id is null or m.created_by<>auth.uid() then raise exception 'Only the creator can cancel this staff meeting';end if;
  if m.version is distinct from (p_payload->>'version')::int or m.cancelled then raise exception 'Meeting changed. Refresh';end if;
  if m.starts_at<=now() then raise exception 'Past staff meetings remain in history';end if;
  v:=m.week;
 else
  if p_payload->>'action' is distinct from 'create' then raise exception 'Choose create or cancel';end if;
  lo:=(p_payload->>'start')::timestamptz;hi:=(p_payload->>'end')::timestamptz;v:=private.planning_week(lo);
  if lo is null or hi is null or lo<=now() or hi<=lo or hi-lo>interval '12 hours' then raise exception 'Choose a future meeting lasting at most 12 hours';end if;
  if nullif(trim(p_payload->>'title'),'') is null or length(p_payload->>'title')>120 or p_payload->>'mode' not in ('separate','within') or p_payload->>'mode' is null then raise exception 'Enter a title and timing mode';end if;
  select array_agg(distinct value) into people from jsonb_array_elements_text(p_payload->'people');
  if coalesce(cardinality(people),0)=0 or cardinality(people)>500 then raise exception 'Choose between 1 and 500 attendees';end if;
 end if;
 select * into w from private.schedule_weeks where week_start=v;
 if w.draft_id is null then perform public.scheduler_action('draft',jsonb_build_object('week',v),gen_random_uuid());select * into w from private.schedule_weeks where week_start=v;end if;
 select * into r from private.schedule_revisions where schedule_revisions.id=w.draft_id for update;
 if r.state='Queued' then raise exception 'Cancel the queued release before changing staff meetings';end if;
 items:=r.shifts;
 if p_payload->>'action'='cancel' then
  for piece in select value from jsonb_array_elements(m.generated) loop
   select x into source from jsonb_array_elements(items) x where x->>'id'=piece->>'id';
   if source is null or (source-'slot') is distinct from (piece-'slot') then raise exception 'Meeting assignments changed. Review the schedule before cancellation';end if;
  end loop;
  select coalesce(jsonb_agg(x),'[]') into items from jsonb_array_elements(items) x where not exists(select 1 from jsonb_array_elements(m.generated) g where g->>'id'=x->>'id');
  items:=items||m.originals;
  update private.staff_meetings set cancelled=true,version=version+1 where staff_meetings.id=m.id;
 else
  foreach p in array people loop
   if not private.person_active(p) then raise exception 'Choose active attendees on the roster';end if;
   if private.person_conflict(p,lo,hi) is not null then raise exception '%: %',private.person_name(p),private.person_conflict(p,lo,hi);end if;
   if p_payload->>'mode'='within' then
    select x into source from jsonb_array_elements(items) x where x->>'person_id'=p and coalesce(x->>'assignment_type','regular')='regular' and (x->>'start')::timestamptz<=lo and (x->>'end')::timestamptz>=hi;
    if source is null then raise exception '% needs one regular work shift covering the entire meeting',private.person_name(p);end if;
    if exists(select 1 from public.training_sessions where status='Scheduled' and (work_shift_id::text=source->>'id' or trainer_shift_id::text=source->>'id')) or exists(select 1 from public.meetings where status='Scheduled' and (work_shift_id::text=source->>'id' or manager_shift_id::text=source->>'id')) then raise exception 'Replan linked coaching or 1:1 before adding a staff meeting';end if;
    originals:=originals||jsonb_build_array(source);
    select coalesce(jsonb_agg(x),'[]') into items from jsonb_array_elements(items) x where x->>'id'<>source->>'id';
    if (source->>'start')::timestamptz<lo then piece:=source||jsonb_build_object('end',lo);items:=items||jsonb_build_array(piece);generated:=generated||jsonb_build_array(piece);end if;
    if (source->>'end')::timestamptz>hi then piece:=source||jsonb_build_object('id',case when (source->>'start')::timestamptz<lo then gen_random_uuid() else (source->>'id')::uuid end,'start',hi);items:=items||jsonb_build_array(piece);generated:=generated||jsonb_build_array(piece);end if;
   end if;
   piece:=jsonb_build_object('id',gen_random_uuid(),'person_id',p,'start',lo,'end',hi,'slot',1,'job_id',null,'assignment_type','training','activity_title',trim(p_payload->>'title'));
   items:=items||jsonb_build_array(piece);generated:=generated||jsonb_build_array(piece);
  end loop;
  insert into private.staff_meetings(id,title,starts_at,ends_at,mode,week,people,originals,generated,created_by) values(v_id,trim(p_payload->>'title'),lo,hi,p_payload->>'mode',v,people,originals,generated,auth.uid());
 end if;
 issues:=private.shift_issues(items,v);
 if cardinality(issues)>0 then raise exception '%',array_to_string(issues,E'\n');end if;
 perform public.scheduler_action('save',jsonb_build_object('id',r.id,'version',r.version,'shifts',items),gen_random_uuid());
 result:=jsonb_build_object('id',v_id,'week',v,'revision',r.id);
 perform private.schedule_audit('staff_meeting:'||(p_payload->>'action'),v_id::text,to_jsonb(m),p_payload);
 insert into private.scheduler_submissions(id,actor,action,payload,result) values(p_submission,auth.uid(),'staff_meeting',p_payload,result);
 return result;
end $$;
-- Registered meeting blocks and their split work segments are edited together.
create function private.guard_staff_meeting_shifts() returns trigger language plpgsql security definer set search_path='' as $$
declare m private.staff_meetings;g jsonb;x jsonb;
begin
 if TG_OP='UPDATE' and new.shifts is not distinct from old.shifts then return new;end if;
 for m in select * from private.staff_meetings where not cancelled and week=(select week_start from private.schedule_weeks where id=new.week_id) loop
  for g in select value from jsonb_array_elements(m.generated) loop
   select s into x from jsonb_array_elements(new.shifts) s where s->>'id'=g->>'id';
   if x is null or (x-'slot') is distinct from (g-'slot') then raise exception 'Use Staff meetings to cancel or replan its linked assignments';end if;
  end loop;
 end loop;return new;
end $$;
create trigger guard_staff_meeting_shifts before insert or update of shifts on private.schedule_revisions for each row execute function private.guard_staff_meeting_shifts();
alter function private.trade_assignment_error(jsonb,text,uuid) rename to trade_assignment_error_before_staff_meetings;
create function private.trade_assignment_error(s jsonb,p text,t uuid default null) returns text language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from private.staff_meetings m cross join lateral jsonb_array_elements(m.generated) g where g->>'id'=s->>'id' and (not m.cancelled or g->>'assignment_type'='training' and s->>'assignment_type'='training')) then 'Replan this staff meeting through its creator before changing assignments' else private.trade_assignment_error_before_staff_meetings(s,p,t) end
$$;
revoke all on function private.guard_staff_meeting_shifts(),private.trade_assignment_error_before_staff_meetings(jsonb,text,uuid),private.trade_assignment_error(jsonb,text,uuid),public.staff_meetings_read(boolean),public.staff_meeting_save(jsonb,uuid) from public,anon,authenticated;
grant execute on function public.staff_meetings_read(boolean),public.staff_meeting_save(jsonb,uuid) to authenticated;
commit;
