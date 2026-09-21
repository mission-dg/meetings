begin;
-- Internal training slots stay stable when another work shift is added or removed.
-- New shifts receive a server-assigned slot, across all jobs for that person/day.
create function private.automatic_shift_slots(p_shifts jsonb,p_previous jsonb) returns jsonb
language plpgsql stable set search_path='' as $$
declare result jsonb:='[]';s jsonb;old jsonb;n integer;day date;
begin
 if jsonb_typeof(p_shifts) is distinct from 'array' or jsonb_array_length(p_shifts)>1000 then raise exception 'Invalid shift list';end if;
 for s in select value from jsonb_array_elements(p_shifts) order by (value->>'start')::timestamptz,value->>'id' loop
  day:=((s->>'start')::timestamptz at time zone 'America/Chicago')::date;
  select value into old from jsonb_array_elements(p_previous) where value->>'id'=s->>'id' and value->>'person_id'=s->>'person_id' and ((value->>'start')::timestamptz at time zone 'America/Chicago')::date=day;
  if old is not null then n:=(old->>'slot')::int;
  else
   select coalesce(max((value->>'slot')::int),0)+1 into n from jsonb_array_elements(p_previous||result)
   where value->>'person_id'=s->>'person_id' and ((value->>'start')::timestamptz at time zone 'America/Chicago')::date=day;
  end if;
  result:=result||jsonb_build_array(s||jsonb_build_object('slot',n));
 end loop;
 return result;
end $$;
revoke all on function private.automatic_shift_slots(jsonb,jsonb) from public,anon,authenticated;
alter table public.training_sessions drop constraint training_sessions_shift_check;
alter table public.training_sessions add constraint training_sessions_shift_check check(shift>0);
-- Seed job labels without assigning any account permissions or altering existing jobs.
insert into public.training_positions(name,department,created_by)
select names.name,'FOH',m.id from (values ('CA'),('TA')) names(name)
cross join lateral (select id from public.manager_profiles where active order by is_admin desc,id limit 1) m
on conflict do nothing;

create or replace function private.shift_issues(p_shifts jsonb,p_week date) returns text[] language plpgsql stable security definer set search_path='' as $$
declare issues text[]:='{}';s jsonb;o jsonb;t record;p text;starts timestamptz;ends timestamptz;job uuid;why text;seen text[]:='{}';
begin
 if jsonb_typeof(p_shifts) is distinct from 'array' or jsonb_array_length(p_shifts)>1000 then return array['A schedule must contain at most 1,000 shifts'];end if;
 for s in select value from jsonb_array_elements(p_shifts) loop
  begin
   perform (s->>'id')::uuid;p:=s->>'person_id';starts:=(s->>'start')::timestamptz;ends:=(s->>'end')::timestamptz;job:=(s->>'job_id')::uuid;
   if s->>'id' is null or p is null or starts is null or ends is null or (s->>'slot')::int<1 or s->>'slot' is null then raise exception 'Missing shift fields';end if;
   if s->>'id'=any(seen) then raise exception 'Duplicate shift ID';end if;seen:=array_append(seen,s->>'id');
   if ends<=starts or ends-starts>interval '24 hours' then raise exception 'Shift end must be after start and no more than 24 hours later';end if;
   if (starts at time zone 'America/Chicago')::date<p_week or (starts at time zone 'America/Chicago')::date>=p_week+7 then raise exception 'Shift must start in this scheduling week';end if;
   if exists(select 1 from private.schedule_weeks ww join private.schedule_revisions rr on rr.id=ww.published_id cross join lateral jsonb_array_elements(rr.shifts) xx where ww.week_start<>p_week and xx->>'id'=s->>'id') then raise exception 'Shift ID is already used in another week';end if;
   if not private.person_active(p) then raise exception 'Choose an active person on the work roster';end if;
   if private.person_is_shl(p) then
    if job is not null then raise exception 'Managers must be scheduled as SHL';end if;
   else
    if not exists(select 1 from public.training_positions where id=job and active) then raise exception 'Choose an active job';end if;
    if not exists(select 1 from public.training_signoffs f join public.training_positions j on j.id=f.training_position_id where f.staff_id=substring(p from 3) and f.training_position_id=job and f.active and private.training_completed_shifts(f.staff_id,job)>=j.target_shifts) and length(trim(coalesce(s->>'qualification_reason','')))=0 then raise exception 'Explain this assignment without a training sign-off';end if;
   end if;
   why:=private.person_conflict(p,starts,ends);if why is not null then raise exception '%',why;end if;
   if exists(select 1 from jsonb_array_elements(p_shifts) x where x->>'id'<>s->>'id' and x->>'person_id'=p and (x->>'start')::timestamptz<ends and (x->>'end')::timestamptz>starts) then raise exception 'Overlapping work shifts';end if;
   if exists(select 1 from private.schedule_weeks w join private.schedule_revisions r on r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) x where w.week_start<>p_week and x->>'person_id'=p and (x->>'start')::timestamptz<ends and (x->>'end')::timestamptz>starts) then raise exception 'Overlap with another published week';end if;
  exception when others then issues:=array_append(issues,private.person_name(s->>'person_id')||': '||sqlerrm);end;
 end loop;return issues;
end $$;
create or replace function private.scheduler_action_v1(p_action text,p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.scheduler_submissions;result jsonb:='{}';w private.schedule_weeks;r private.schedule_revisions;q private.scheduler_requests;a private.announcements;before jsonb;v date;s jsonb;t jsonb;x jsonb;new_shifts jsonb;issues text[];p text;v_id uuid;counter int;range_value jsonb;day_value jsonb;last_end int;starts timestamptz;ends timestamptz;recipient text;rev_id uuid;wk record;source jsonb;target jsonb;
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.scheduler_member() then raise exception 'Active workspace access required';end if;
 if p_submission is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Submission information is required';end if;
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then
  if prior.actor<>auth.uid() or prior.action<>p_action or prior.payload<>p_payload then raise exception 'Submission changed. Reload before saving';end if;
  return prior.result;
 end if;
 if p_action in ('draft','save','review','release','queue','unqueue','rebase','roster') and not private.is_manager() then raise exception 'Manager access required';end if;
 if p_action='draft' then
  v:=(p_payload->>'week')::date;if v is null or extract(dow from v)<>0 then raise exception 'Choose a Sunday';end if;
  insert into private.schedule_weeks(week_start) values(v) on conflict do nothing;
  select * into w from private.schedule_weeks where week_start=v for update;
  if w.draft_id is not null then raise exception 'A draft already exists. Reload it';end if;
  select * into r from private.schedule_revisions where id=w.published_id;
  new_shifts:=coalesce(r.shifts,'[]');
  if coalesce((p_payload->>'copy_previous')::boolean,false) then
   select coalesce(rr.shifts,'[]') into new_shifts from private.schedule_weeks ww join private.schedule_revisions rr on rr.id=ww.published_id where ww.week_start=v-7;
   if exists(select 1 from jsonb_array_elements(coalesce(new_shifts,'[]')) cs cross join lateral (values ((cs->>'start')::timestamptz),((cs->>'end')::timestamptz)) dt(v) where (((dt.v at time zone 'America/Chicago'+interval '7 days') at time zone 'America/Chicago') at time zone 'America/Chicago')<>dt.v at time zone 'America/Chicago'+interval '7 days') then raise exception 'A copied shift falls in a daylight-saving gap. Create the draft manually and choose valid times';end if;
   select coalesce(jsonb_agg(copy_shift||jsonb_build_object('id',gen_random_uuid(),'start',((copy_shift->>'start')::timestamptz at time zone 'America/Chicago'+interval '7 days') at time zone 'America/Chicago','end',((copy_shift->>'end')::timestamptz at time zone 'America/Chicago'+interval '7 days') at time zone 'America/Chicago')),'[]') into new_shifts from jsonb_array_elements(coalesce(new_shifts,'[]')) copy_shift;
  end if;
  insert into private.schedule_revisions(week_id,base_id,shifts,created_by) values(w.id,w.published_id,new_shifts,auth.uid()) returning * into r;
  update private.schedule_weeks set draft_id=r.id where id=w.id;
  result:=jsonb_build_object('id',r.id);
 elsif p_action in ('save','review','release','queue','unqueue','rebase') then
  select * into r from private.schedule_revisions where id=(p_payload->>'id')::uuid for update;
  if not found or r.version<>(p_payload->>'version')::int or p_payload->>'version' is null then raise exception 'This draft changed. Reload before saving';end if;
  select * into w from private.schedule_weeks where id=r.week_id for update;
  if w.draft_id is distinct from r.id then raise exception 'This is no longer the current draft';end if;
  before:=to_jsonb(r);
  if p_action='unqueue' then
   if r.state<>'Queued' then raise exception 'This release is not queued';end if;
   update private.schedule_revisions set state='Draft',release_at=null,release_by=null,error=null,version=version+1 where id=r.id;
  else
   if r.state='Queued' then raise exception 'Cancel the queued release before making changes';end if;
   if p_action='save' then
    new_shifts:=private.automatic_shift_slots(p_payload->'shifts',r.shifts);issues:=private.shift_issues(new_shifts,w.week_start);
    -- Drafts may contain planning conflicts but must remain bounded and structurally valid.
    if jsonb_typeof(new_shifts) is distinct from 'array' or jsonb_array_length(new_shifts)>1000 then raise exception 'Invalid shift list';end if;
    for s in select value from jsonb_array_elements(new_shifts) loop
     perform (s->>'id')::uuid,(s->>'start')::timestamptz,(s->>'end')::timestamptz;
     if s->>'id' is null or s->>'person_id' is null or s->>'start' is null or s->>'end' is null then raise exception 'Incomplete shift';end if;
    end loop;
    update private.schedule_revisions set shifts=new_shifts,state='Draft',error=null,version=version+1 where id=r.id;
    result:=jsonb_build_object('issues',issues);
   elsif p_action='rebase' then
    -- Explicit recovery replaces the stale draft with the current publication, preserving audit and training records.
    if exists(select 1 from public.training_sessions where schedule_revision_id=r.id and status='Scheduled') then raise exception 'Cancel or move draft training before reloading the published schedule';end if;
    select shifts into new_shifts from private.schedule_revisions where id=w.published_id;
    update private.schedule_revisions set shifts=coalesce(new_shifts,'[]'),base_id=w.published_id,state='Draft',error=null,version=version+1 where id=r.id;
   else
    issues:=private.shift_issues(r.shifts,w.week_start)||private.training_issues(r.shifts,w.week_start,r.id);
    if w.published_id is distinct from r.base_id then issues:=array_append(issues,'Published schedule changed. Reload the published version before release');end if;
    if p_action='review' then result:=jsonb_build_object('issues',issues,'shifts',r.shifts,'training',(select coalesce(jsonb_agg(to_jsonb(tt)),'[]') from public.training_sessions tt where tt.schedule_revision_id=r.id or tt.work_shift_id::text in (select sx->>'id' from jsonb_array_elements(r.shifts) sx)));
    else
     if cardinality(issues)>0 then raise exception '%',array_to_string(issues,E'\n');end if;
     if p_action='queue' then
      starts:=(p_payload->>'release_at')::timestamptz;
      if starts is null or starts<=now() then raise exception 'Choose a future release time';end if;
      if exists(select 1 from jsonb_array_elements(r.shifts) ss where (ss->>'start')::timestamptz<starts and not exists(select 1 from private.schedule_revisions rr cross join lateral jsonb_array_elements(rr.shifts) os where rr.id=w.published_id and os=ss)) then raise exception 'Release the schedule before a new or changed shift starts';end if;
      update private.schedule_revisions set state='Queued',release_at=starts,release_by=auth.uid(),error=null,version=version+1 where id=r.id;
      result:=jsonb_build_object('state','Queued');
     else
      update private.schedule_revisions set release_by=auth.uid() where id=r.id;
      result:=private.release_revision(r.id);
     end if;
    end if;
   end if;
  end if;
  perform private.schedule_audit(p_action,r.id::text,before,(select to_jsonb(rr) from private.schedule_revisions rr where rr.id=r.id));
 elsif p_action='roster' then
  if not private.is_admin() then raise exception 'IT Admin access required';end if;
  update public.manager_profiles set on_roster=(p_payload->>'on_roster')::boolean,version=version+1 where id=(p_payload->>'id')::uuid and version=(p_payload->>'version')::int;
  if not found then raise exception 'Account changed. Reload';end if;
 elsif p_action='request' then
  p:=private.my_person();if not private.person_active(p) then raise exception 'You must be on the work roster to submit a request';end if;
  if p_payload->>'kind' in ('Availability','Time off') then
   if p_payload->>'kind'='Time off' then
    starts:=(p_payload->'details'->>'start')::timestamptz;ends:=(p_payload->'details'->>'end')::timestamptz;
    if starts is null or ends is null or ends<=starts or ends<=now() then raise exception 'Choose a valid upcoming time-off range';end if;
   else
    v:=(p_payload->'details'->>'effective')::date;
    if v is null or v<(now() at time zone 'America/Chicago')::date or jsonb_typeof(p_payload->'details'->'days') is distinct from 'array' or jsonb_array_length(p_payload->'details'->'days')<>7 then raise exception 'Choose a future effective date and all seven weekdays';end if;
    for day_value in select value from jsonb_array_elements(p_payload->'details'->'days') loop
     if jsonb_typeof(day_value) is distinct from 'array' then raise exception 'Invalid availability';end if;last_end:=-1;
     for range_value in select value from jsonb_array_elements(day_value) loop
      if jsonb_typeof(range_value) is distinct from 'array' or jsonb_array_length(range_value)<>2 or jsonb_typeof(range_value->0) is distinct from 'number' or jsonb_typeof(range_value->1) is distinct from 'number' or (range_value->>0)::int<0 or (range_value->>1)::int>1440 or (range_value->>0)::int>=(range_value->>1)::int or (range_value->>0)::int<last_end then raise exception 'Availability ranges must be ordered, non-overlapping, and within one day';end if;
      last_end:=(range_value->>1)::int;
     end loop;
    end loop;
   end if;
   insert into private.scheduler_requests(kind,person_id,created_by,payload,reason) values(p_payload->>'kind',p,auth.uid(),p_payload->'details',left(coalesce(p_payload->>'reason',''),2000)) returning id into v_id;
  else
   if p_payload->>'kind' not in ('Trade','Coverage','Offer') then raise exception 'Choose a request type';end if;
   s:=private.find_shift((p_payload->>'source_id')::uuid);
   if s is null or s->>'person_id'<>p or (s->>'start')::timestamptz<=now() then raise exception 'Choose your own upcoming published shift';end if;
   if exists(select 1 from public.training_sessions where status='Scheduled' and (work_shift_id::text=s->>'id' or trainer_shift_id::text=s->>'id')) then raise exception 'Ask a manager to replan linked training before offering this shift';end if;
   t:=null;recipient:=null;
   if p_payload->>'kind'='Trade' then
    t:=private.find_shift((p_payload->>'target_id')::uuid);recipient:=t->>'person_id';
    if t is null or (t->>'start')::timestamptz<=now() or exists(select 1 from public.training_sessions where status='Scheduled' and (work_shift_id::text=t->>'id' or trainer_shift_id::text=t->>'id')) then raise exception 'Choose an upcoming shift without linked training';end if;
   elsif p_payload->>'kind'='Coverage' then recipient:=p_payload->>'recipient';end if;
   if p_payload->>'kind'<>'Offer' and (recipient is null or recipient=p or not private.person_active(recipient) or private.person_is_shl(recipient) is distinct from private.person_is_shl(p)) then raise exception 'Choose another eligible coworker';end if;
   insert into private.scheduler_requests(kind,person_id,created_by,payload,reason) values(p_payload->>'kind',p,auth.uid(),jsonb_build_object('source',s-'qualification_reason','target',t-'qualification_reason','recipient',recipient),left(coalesce(p_payload->>'reason',''),2000)) returning id into v_id;
   if recipient is not null then perform private.notify_person(recipient,'request:'||v_id,'A coworker requested a shift change. Review it in Requests.');end if;
  end if;
  perform private.notify_managers('request:'||v_id,'A new '||lower(p_payload->>'kind')||' request is waiting for review.');
  result:=jsonb_build_object('id',v_id);
 elsif p_action in ('withdraw','accept','decide','revoke') then
  select * into q from private.scheduler_requests where id=(p_payload->>'id')::uuid for update;
  if not found or q.version<>(p_payload->>'version')::int or p_payload->>'version' is null then raise exception 'This request changed. Reload';end if;
  if q.status not in ('Pending','Accepted') and not (p_action='revoke' and q.status='Approved' and q.kind in ('Availability','Time off')) then raise exception 'This request is no longer pending';end if;
  before:=to_jsonb(q);
  if p_action='revoke' then
   if not private.is_manager() or q.created_by=auth.uid() or length(trim(coalesce(p_payload->>'response','')))=0 then raise exception 'Another manager must explain withdrawing this approval';end if;
   update private.scheduler_requests set status='Withdrawn',response=p_payload->>'response',decided_by=auth.uid(),decided_at=now(),version=version+1 where id=q.id;
   for s in select * from private.published_shifts() loop
    if s->>'person_id'=q.person_id and (s->>'end')::timestamptz>now() and private.person_conflict(q.person_id,(s->>'start')::timestamptz,(s->>'end')::timestamptz) is not null then raise exception 'Resolve published conflicts before restoring earlier availability';end if;
   end loop;
   perform private.notify_person(q.person_id,'revoke:'||q.id,'A manager withdrew approval of your scheduling request. See Requests for the explanation.');
  elsif p_action='withdraw' then
   if q.created_by<>auth.uid() then raise exception 'Only the requester can withdraw';end if;
   update private.scheduler_requests set status='Withdrawn',version=version+1 where id=q.id;
  elsif p_action='accept' then
   if q.status<>'Pending' or q.kind not in ('Trade','Coverage','Offer') or q.created_by=auth.uid() or not private.person_active(private.my_person()) then raise exception 'This request cannot be accepted';end if;
   if q.kind<>'Offer' and q.payload->>'recipient'<>private.my_person() then raise exception 'This request is for another coworker';end if;
   if private.person_is_shl(q.person_id) is distinct from private.person_is_shl(private.my_person()) then raise exception 'This shift requires the same staff or SHL role';end if;
   source:=private.find_shift((q.payload->'source'->>'id')::uuid);
   if source is null or source-'qualification_reason'<>q.payload->'source' or (source->>'start')::timestamptz<=now() then raise exception 'This shift changed or started';end if;
   update private.scheduler_requests set status='Accepted',claimed_by=auth.uid(),payload=payload||jsonb_build_object('recipient',private.my_person()),version=version+1 where id=q.id;
   perform private.notify_managers('accepted:'||q.id,'A shift request was accepted and needs manager approval.');
   perform private.notify_person(q.person_id,'accepted:'||q.id,'Your shift request was accepted and is waiting for manager approval.');
  else
   if not private.is_manager() or q.created_by=auth.uid() or q.claimed_by=auth.uid() then raise exception 'Another manager must decide this request';end if;
   if p_payload->>'decision' is null or p_payload->>'decision' not in ('Approved','Rejected') then raise exception 'Choose an approval decision';end if;
   if p_payload->>'decision'='Approved' then
    if q.kind in ('Availability','Time off') then
     update private.scheduler_requests set status='Approved',decided_by=auth.uid(),decided_at=now(),response=left(coalesce(p_payload->>'response',''),2000),version=version+1 where id=q.id;
     for s in select * from private.published_shifts() loop
      if s->>'person_id'=q.person_id and (s->>'end')::timestamptz>now() and private.person_conflict(q.person_id,(s->>'start')::timestamptz,(s->>'end')::timestamptz) is not null then raise exception 'Resolve conflicting published shifts before approving: % to % (Central)',to_char((s->>'start')::timestamptz at time zone 'America/Chicago','Mon DD, YYYY HH24:MI'),to_char((s->>'end')::timestamptz at time zone 'America/Chicago','Mon DD, YYYY HH24:MI');end if;
     end loop;
    else
     if q.status<>'Accepted' then raise exception 'A coworker must accept first';end if;
     source:=private.find_shift((q.payload->'source'->>'id')::uuid);target:=private.find_shift((q.payload->'target'->>'id')::uuid);
     if source is null or source-'qualification_reason'<>q.payload->'source' or (source->>'start')::timestamptz<=now() or (q.kind='Trade' and (target is null or target-'qualification_reason'<>q.payload->'target' or (target->>'start')::timestamptz<=now())) then raise exception 'A shift changed or started. Submit a new request';end if;
     if exists(select 1 from public.training_sessions where status='Scheduled' and (work_shift_id::text in (source->>'id',target->>'id') or trainer_shift_id::text in (source->>'id',target->>'id'))) then raise exception 'Replan linked training first';end if;
     if not exists(select 1 from private.employee_accounts ac join public.staff st on st.id=ac.staff_id where ac.id=q.claimed_by and ac.active and st.active) and not exists(select 1 from public.manager_profiles where id=q.claimed_by and active and on_roster) then raise exception 'The accepting coworker no longer has access';end if;
     -- Update all affected publications before validation, so cross-week trades validate their final state.
     for wk in select ww.* from private.schedule_weeks ww join private.schedule_revisions rr on rr.id=ww.published_id where exists(select 1 from jsonb_array_elements(rr.shifts) z where z->>'id' in (source->>'id',target->>'id')) order by ww.week_start loop
      select * into r from private.schedule_revisions where id=wk.published_id;
      select jsonb_agg(case when ss->>'id'=source->>'id' then ss||jsonb_build_object('person_id',q.payload->>'recipient','qualification_reason',coalesce(p_payload->>'qualification_reason','')) when ss->>'id'=target->>'id' then ss||jsonb_build_object('person_id',q.person_id,'qualification_reason',coalesce(p_payload->>'qualification_reason','')) else ss end) into new_shifts from jsonb_array_elements(r.shifts) ss;
      insert into private.schedule_revisions(week_id,base_id,shifts,created_by,state,release_by,released_at) values(wk.id,r.id,new_shifts,auth.uid(),'Published',auth.uid(),now()) returning id into rev_id;
      update private.schedule_weeks set published_id=rev_id where id=wk.id;
     end loop;
     for wk in select ww.week_start,rr.shifts from private.schedule_weeks ww join private.schedule_revisions rr on rr.id=ww.published_id where exists(select 1 from jsonb_array_elements(rr.shifts) z where z->>'id' in (source->>'id',target->>'id')) loop
      issues:=private.shift_issues(wk.shifts,wk.week_start);if cardinality(issues)>0 then raise exception '%',array_to_string(issues,E'\n');end if;
     end loop;
     update private.scheduler_requests set status='Approved',decided_by=auth.uid(),decided_at=now(),response=left(coalesce(p_payload->>'response',''),2000),version=version+1 where id=q.id;
     perform private.expire_shift_requests();
    end if;
   else update private.scheduler_requests set status='Rejected',decided_by=auth.uid(),decided_at=now(),response=left(coalesce(p_payload->>'response',''),2000),version=version+1 where id=q.id;
   end if;
   perform private.notify_person(q.person_id,'decision:'||q.id,'Your '||lower(q.kind)||' request was '||lower(p_payload->>'decision')||'.');
   if q.claimed_by is not null then perform private.notify_person(q.payload->>'recipient','decision:'||q.id,'The shift request you accepted was '||lower(p_payload->>'decision')||'.');end if;
  end if;
  perform private.schedule_audit(p_action,q.id::text,before,(select to_jsonb(z) from private.scheduler_requests z where z.id=q.id));
 elsif p_action in ('training_save','training_status','training_job') then
  if not private.can_training() then raise exception 'Manager or CA access required';end if;
  if p_payload->>'id' is not null then
   if not exists(select 1 from public.training_sessions ts where ts.id=(p_payload->>'id')::uuid and ts.created_by=auth.uid() and ts.version=(p_payload->>'version')::int) then raise exception 'Training changed or belongs to another creator';end if;
  elsif p_action<>'training_save' then raise exception 'Choose a training session';end if;
  if p_action='training_status' then
   if p_payload->>'status' not in ('Completed','Missed','Cancelled') then raise exception 'Choose an outcome';end if;
   update public.training_sessions set status=p_payload->>'status' where id=(p_payload->>'id')::uuid;
  elsif p_action='training_job' then
   update public.training_sessions set training_position_id=(p_payload->>'training_position_id')::uuid where id=(p_payload->>'id')::uuid;
  elsif p_payload->>'id' is null then
   insert into public.training_sessions(staff_id,trainer_id,training_position_id,shift,scheduled_at,ends_at,work_shift_id,trainer_shift_id,schedule_revision_id)
   values(p_payload->>'staff_id',p_payload->>'trainer_id',(p_payload->>'training_position_id')::uuid,(p_payload->>'shift')::int,(p_payload->>'scheduled_at')::timestamptz,(p_payload->>'ends_at')::timestamptz,(p_payload->>'work_shift_id')::uuid,(p_payload->>'trainer_shift_id')::uuid,(p_payload->>'schedule_revision_id')::uuid) returning id into v_id;
   result:=jsonb_build_object('id',v_id);
  else
   update public.training_sessions set staff_id=p_payload->>'staff_id',trainer_id=p_payload->>'trainer_id',training_position_id=(p_payload->>'training_position_id')::uuid,shift=(p_payload->>'shift')::int,scheduled_at=(p_payload->>'scheduled_at')::timestamptz,ends_at=(p_payload->>'ends_at')::timestamptz,work_shift_id=(p_payload->>'work_shift_id')::uuid,trainer_shift_id=(p_payload->>'trainer_shift_id')::uuid,schedule_revision_id=(p_payload->>'schedule_revision_id')::uuid where id=(p_payload->>'id')::uuid;
  end if;
 elsif p_action='announcement' then
  if not private.can_training() then raise exception 'Manager or CA access required';end if;
  if length(trim(coalesce(p_payload->>'title',''))) not between 1 and 160 or length(trim(coalesce(p_payload->>'body',''))) not between 1 and 10000 then raise exception 'Provide a title and announcement text';end if;
  if jsonb_typeof(p_payload->'groups') is distinct from 'array' or exists(select 1 from jsonb_array_elements_text(p_payload->'groups') g where g not in ('FOH','BOH','Catering','SHL')) then raise exception 'Choose valid position groups';end if;
  if p_payload->>'id' is null then
   insert into private.announcements(title,body,groups,created_by) values(trim(p_payload->>'title'),trim(p_payload->>'body'),array(select jsonb_array_elements_text(p_payload->'groups')),auth.uid()) returning * into a;
  else
   select * into a from private.announcements where id=(p_payload->>'id')::uuid for update;
   if not found or a.created_by<>auth.uid() or a.version<>(p_payload->>'version')::int or p_payload->>'version' is null then raise exception 'Only the author can edit an unchanged announcement';end if;
   before:=to_jsonb(a);
   if (a.title,a.body,a.groups,a.active) is distinct from (trim(p_payload->>'title'),trim(p_payload->>'body'),array(select jsonb_array_elements_text(p_payload->'groups')),coalesce((p_payload->>'active')::boolean,true)) then
   update private.announcements set title=trim(p_payload->>'title'),body=trim(p_payload->>'body'),groups=array(select jsonb_array_elements_text(p_payload->'groups')),active=coalesce((p_payload->>'active')::boolean,true),version=version+1,updated_at=now() where id=a.id returning * into a;
   end if;
  end if;
  perform private.schedule_audit('announcement',a.id::text,before,to_jsonb(a));result:=jsonb_build_object('id',a.id);
 elsif p_action='read' then
  if p_payload->>'announcement_id' is not null then
   select * into a from private.announcements where id=(p_payload->>'announcement_id')::uuid;
   if not found or not a.active or not (cardinality(a.groups)=0 or (case when private.is_manager() then 'SHL' else (select department from public.staff where id=private.employee_staff()) end)=any(a.groups) or a.created_by=auth.uid()) then raise exception 'Announcement unavailable';end if;
   insert into private.announcement_reads values(auth.uid(),a.id,a.version) on conflict(user_id,announcement_id) do update set version=excluded.version;
  else update private.scheduler_notifications set read_at=now() where user_id=auth.uid() and (p_payload->>'id' is null or id=(p_payload->>'id')::uuid);end if;
 elsif p_action='employee_access' then
  if not private.is_admin() then raise exception 'IT Admin access required';end if;
  if not exists(select 1 from private.employee_accounts where id=(p_payload->>'id')::uuid and version=(p_payload->>'version')::int) then raise exception 'Account changed. Reload';end if;
  select to_jsonb(ac) into before from private.employee_accounts ac where id=(p_payload->>'id')::uuid;
  update private.employee_accounts set active=(p_payload->>'active')::boolean,is_ca=(p_payload->>'is_ca')::boolean,version=version+1 where id=(p_payload->>'id')::uuid;
  perform private.schedule_audit('employee_access',p_payload->>'id',before,p_payload);
 elsif p_action='email_verified' then
  if not private.is_admin() then raise exception 'IT Admin access required';end if;
  if coalesce((p_payload->>'verified')::boolean,false) and length(trim(coalesce(p_payload->>'evidence','')))<12 then raise exception 'Record the verified sender and successful invitation/reset delivery test';end if;
  update private.scheduler_settings set email_verified=(p_payload->>'verified')::boolean,email_evidence=p_payload->>'evidence';
  perform private.schedule_audit('email_verified','settings',null,p_payload);
 else raise exception 'Unknown scheduler action';end if;
 insert into private.scheduler_submissions values(p_submission,auth.uid(),p_action,p_payload,result);
 return result;
end $$;
commit;
