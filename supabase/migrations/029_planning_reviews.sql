begin;
create table private.coverage_rules(id boolean primary key default true check(id),version int not null default 1,days jsonb not null default '[]',updated_by uuid references auth.users(id));
insert into private.coverage_rules default values;
create table private.period_forecasts(day date primary key,lunch numeric(14,2) not null check(lunch>=0),dinner numeric(14,2) not null check(dinner>=0),version int not null default 1);
create table private.coverage_overrides(day date primary key,targets jsonb not null,reason text not null,version int not null default 1,actor uuid not null references auth.users(id));
create table private.planning_reviews(id uuid primary key,kind text not null,fingerprint text not null,assessment jsonb not null,reason text not null,actor uuid not null references auth.users(id),reviewed_at timestamptz not null default now());
alter table private.coverage_rules enable row level security;
alter table private.period_forecasts enable row level security;
alter table private.coverage_overrides enable row level security;
alter table private.planning_reviews enable row level security;
revoke all on private.coverage_rules,private.period_forecasts,private.coverage_overrides,private.planning_reviews from public,anon,authenticated;

create function private.planning_week(t timestamptz) returns date language sql immutable set search_path='' as $$select (t at time zone 'America/Chicago')::date-extract(dow from t at time zone 'America/Chicago')::int$$;
create function private.planning_shifts(p_revision uuid default null) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(s order by s->>'id'),'[]') from (
 select s from private.schedule_weeks w join private.schedule_revisions r on r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) s where p_revision is null or w.id<>(select week_id from private.schedule_revisions where id=p_revision)
 union all select s from private.schedule_revisions r cross join lateral jsonb_array_elements(r.shifts) s where r.id=p_revision) z
$$;
create function private.planning_assessment(p_shifts jsonb,p_weeks date[],p_people text[] default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare hrs jsonb;cov jsonb:='[]';missing jsonb:='[]';cfg private.coverage_rules;day_value date;weekday jsonb;period jsonb;band jsonb;targets jsonb;ov private.coverage_overrides;f private.sales_forecasts;pf private.period_forecasts;sales numeric;start_at timestamptz;end_at timestamptz;job record;segment record;needed int;actual int;result jsonb;metadata jsonb:='[]';
begin
 select * into cfg from private.coverage_rules;
 select coalesce(jsonb_agg(to_jsonb(z) order by week,person_id),'[]') into hrs from (
 select w week,s->>'person_id' person_id,private.person_name(s->>'person_id') name,round(sum(extract(epoch from least((s->>'end')::timestamptz,(w+7)::timestamp at time zone 'America/Chicago')-greatest((s->>'start')::timestamptz,w::timestamp at time zone 'America/Chicago')))/3600,4) hours
 from unnest(p_weeks) w cross join lateral (select distinct on (value->>'id') value s from jsonb_array_elements(p_shifts)) q
 where (s->>'start')::timestamptz<(w+7)::timestamp at time zone 'America/Chicago' and (s->>'end')::timestamptz>w::timestamp at time zone 'America/Chicago' and private.person_employment(s->>'person_id')<>'Salaried' and (p_people is null or s->>'person_id'=any(p_people)) group by w,s->>'person_id') z;
 if p_people is not null then
  hrs:=hrs||coalesce((select jsonb_agg(jsonb_build_object('person_id',p,'name',private.person_name(p),'week',w,'hours',0)) from unnest(p_people) p cross join unnest(p_weeks) w where private.person_employment(p)<>'Salaried' and not exists(select 1 from jsonb_array_elements(hrs) h where h->>'person_id'=p and (h->>'week')::date=w)),'[]'::jsonb);
 end if;
 for day_value in select distinct w+i from unnest(p_weeks) w cross join generate_series(0,6) i order by 1 loop
  select value into weekday from jsonb_array_elements(cfg.days) where (value->>'dow')::int=extract(dow from day_value)::int;
  select * into f from private.sales_forecasts where day=day_value;
  select * into pf from private.period_forecasts where day=day_value;
  select * into ov from private.coverage_overrides where day=day_value;
  metadata:=metadata||jsonb_build_array(jsonb_build_object('day',day_value,'forecast',to_jsonb(f),'period',to_jsonb(pf),'override',to_jsonb(ov)));
  if weekday is null or f.day is null or (pf.day is not null and pf.lunch+pf.dinner<>f.amount) then missing:=missing||jsonb_build_array(jsonb_build_object('day',day_value,'message','Coverage setup needed: configure weekday staffing and a reconciled sales forecast'));continue;end if;
  for period in select value from jsonb_array_elements(weekday->'periods') loop
   sales:=case when pf.day is not null then case when period->>'name'='Lunch' then pf.lunch else pf.dinner end else case when period->>'name'='Lunch' then round(f.amount*(weekday->>'lunch_percent')::numeric/100,2) else f.amount-round(f.amount*(weekday->>'lunch_percent')::numeric/100,2) end end;
   select value into band from jsonb_array_elements(period->'bands') where sales>=(value->>'min')::numeric and (value->>'max' is null or sales<(value->>'max')::numeric);
   targets:=band->'jobs';
   if ov.day is not null then select value->'jobs' into targets from jsonb_array_elements(ov.targets) where value->>'name'=period->>'name';end if;
   if targets is null then missing:=missing||jsonb_build_array(jsonb_build_object('day',day_value,'message','Coverage setup needed: no sales band for '||(period->>'name')));continue;end if;
   start_at:=(day_value+(period->>'start')::time) at time zone 'America/Chicago';end_at:=(day_value+(period->>'end')::time+case when (period->>'end')::time<=(period->>'start')::time then interval '1 day' else interval '0' end) at time zone 'America/Chicago';
   for job in select j.key,j.value::text::int n from jsonb_each(targets) j loop
    needed:=job.n;
    for segment in with bounds as (
     select start_at t union select end_at union select greatest(start_at,(s->>'start')::timestamptz) from jsonb_array_elements(p_shifts) s where s->>'job_id'=job.key and (s->>'start')::timestamptz<end_at and (s->>'end')::timestamptz>start_at
     union select least(end_at,(s->>'end')::timestamptz) from jsonb_array_elements(p_shifts) s where s->>'job_id'=job.key and (s->>'start')::timestamptz<end_at and (s->>'end')::timestamptz>start_at)
     select t,lead(t) over(order by t) e from bounds loop
     if segment.e is null then continue;end if;
     select count(distinct s->>'person_id') into actual from jsonb_array_elements(p_shifts) s where s->>'job_id'=job.key and coalesce(s->>'assignment_type','regular')='regular' and private.person_active(s->>'person_id') and (s->>'start')::timestamptz<=segment.t and (s->>'end')::timestamptz>=segment.e;
     cov:=cov||jsonb_build_array(jsonb_build_object('day',day_value,'period',period->>'name','job_id',job.key,'job',(select name from public.training_positions where id=job.key::uuid),'start',segment.t,'end',segment.e,'needed',needed,'scheduled',actual,'shortage',greatest(0,needed-actual),'excess',greatest(0,actual-needed),'minutes',extract(epoch from segment.e-segment.t)/60));
    end loop;
   end loop;
  end loop;
 end loop;
 result:=jsonb_build_object('hours',hrs,'coverage',cov,'missing',missing,'requires_ack',exists(select 1 from jsonb_array_elements(hrs) h where (h->>'hours')::numeric>=35) or jsonb_array_length(missing)>0 or exists(select 1 from jsonb_array_elements(cov) c where (c->>'shortage')::int>0));
 return result||jsonb_build_object('fingerprint',md5((result||jsonb_build_object('rule_version',cfg.version,'inputs',metadata))::text));
end $$;
create function private.revision_assessment(p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare w date;shifts jsonb;weeks date[];
begin
 select week_start into w from private.schedule_weeks where id=(select week_id from private.schedule_revisions where id=p_id);
 if w is null then raise exception 'Schedule not found';end if;
 shifts:=private.planning_shifts(p_id);
 select array_agg(distinct x order by x) into weeks from (select w x union all select private.planning_week((s->>'end')::timestamptz-interval '1 microsecond') from private.schedule_revisions r cross join lateral jsonb_array_elements(r.shifts) s where r.id=p_id) t;
 return private.planning_assessment(shifts,weeks)||jsonb_build_object('revision_id',p_id);
end $$;
create function private.check_planning_review(p_id uuid,p_kind text,p_assessment jsonb,p_payload jsonb) returns void language plpgsql security definer set search_path='' as $$
begin
 if p_payload->>'fingerprint' is distinct from p_assessment->>'fingerprint' then raise exception 'Hours or coverage changed. Refresh and review again';end if;
 if (p_assessment->>'requires_ack')::boolean and (coalesce((p_payload->>'acknowledged')::boolean,false)=false or length(btrim(coalesce(p_payload->>'review_reason','')))<3) then raise exception 'Acknowledge the 35+ hour warnings, coverage gaps or missing setup and enter a reason';end if;
 insert into private.planning_reviews(id,kind,fingerprint,assessment,reason,actor) values(p_id,p_kind,p_assessment->>'fingerprint',p_assessment,left(coalesce(p_payload->>'review_reason',''),2000),auth.uid()) on conflict(id) do update set fingerprint=excluded.fingerprint,assessment=excluded.assessment,reason=excluded.reason,actor=excluded.actor,reviewed_at=now();
 perform private.schedule_audit('planning_acknowledgment',p_id::text,null,jsonb_build_object('assessment',p_assessment,'reason',p_payload->>'review_reason'));
end $$;
-- Worker and immediate release use the same authoritative assessment.
alter function private.release_revision(uuid) rename to release_revision_before_planning;
create function private.release_revision(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;r private.schedule_revisions;review private.planning_reviews;
begin
 perform pg_advisory_xact_lock(61902028);
 select * into r from private.schedule_revisions where id=p_id for update;
 if r.state='Published' then return jsonb_build_object('state','Published','id',p_id);end if;
 a:=private.revision_assessment(p_id);select * into review from private.planning_reviews where id=p_id and kind='release';
 if review.id is null or review.fingerprint<>a->>'fingerprint' then
  update private.schedule_revisions set state='Attention',error='Hours or coverage changed, or review is missing. Review and acknowledge before releasing.',version=version+1 where id=p_id;
  perform private.notify_managers('release-attention:'||p_id||':'||r.version,'Schedule release needs attention: hours or coverage must be reviewed again.');
  return jsonb_build_object('state','Attention','issues',jsonb_build_array('Hours or coverage require a new review'));
 end if;
 return private.release_revision_before_planning(p_id);
end $$;
create function private.trade_assignment_error(s jsonb,p_person text,p_other uuid default null) returns text language plpgsql stable security definer set search_path='' as $$
declare sid text;why text;k text:=coalesce(s->>'assignment_type','regular');
begin
 if s is null or (s->>'start')::timestamptz<=now() then return 'Shift changed or started';end if;
 if not private.person_active(p_person) then return 'Person is inactive';end if;
 if not exists(select 1 from private.employee_accounts a where 's:'||a.staff_id=p_person and a.active) and not exists(select 1 from public.manager_profiles m where m.active and (case when m.linked_staff_id is null then 'm:'||m.id::text else 's:'||m.linked_staff_id end)=p_person) then return 'Coworker needs an active account';end if;
 if exists(select 1 from public.training_sessions t where t.status='Scheduled' and (t.work_shift_id::text=s->>'id' or t.trainer_shift_id::text=s->>'id')) or exists(select 1 from public.meetings m where m.status='Scheduled' and (m.work_shift_id::text=s->>'id' or m.manager_shift_id::text=s->>'id')) then return 'A manager must replan linked training or meetings';end if;
 if k in ('opening_office','closing_office') or k='regular' and s->>'job_id' is null then
  if not private.person_is_shl(p_person) or k<>'regular' and private.person_employment(p_person)='Unclassified' then return 'Assignment requires an eligible SHL';end if;
 elsif k='regular' then
  sid:=case when left(p_person,2)='s:' then substr(p_person,3) else (select linked_staff_id from public.manager_profiles where 'm:'||id::text=p_person) end;
  if not exists(select 1 from public.training_positions where id=(s->>'job_id')::uuid and active) or not private.job_qualified(sid,(s->>'job_id')::uuid) then return 'Job qualification required';end if;
 end if;
 why:=private.person_conflict(p_person,(s->>'start')::timestamptz,(s->>'end')::timestamptz);if why is not null then return 'Availability or time-off conflict';end if;
 if exists(select 1 from private.published_shifts() x where x->>'person_id'=p_person and x->>'id'<>s->>'id' and (p_other is null or x->>'id'<>p_other::text) and (x->>'start')::timestamptz<(s->>'end')::timestamptz and (x->>'end')::timestamptz>(s->>'start')::timestamptz) then return 'Overlapping shift';end if;
 return null;
end $$;
create function private.request_assessment(p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare q private.scheduler_requests;s jsonb;t jsonb;proposed jsonb;original jsonb;weeks date[];a jsonb;b jsonb;why text;
begin
 select * into q from private.scheduler_requests where id=p_id;
 if q.id is null or q.kind not in ('Trade','Coverage','Offer') or q.status<>'Accepted' then raise exception 'Choose an accepted shift request';end if;
 s:=private.find_shift((q.payload->'source'->>'id')::uuid);t:=private.find_shift((q.payload->'target'->>'id')::uuid);
 if s is null or s-'qualification_reason'<>q.payload->'source' or q.kind='Trade' and (t is null or t-'qualification_reason'<>q.payload->'target') then raise exception 'A shift changed. Submit a new request';end if;
 why:=private.trade_assignment_error(s,q.payload->>'recipient',(t->>'id')::uuid);if why is not null then raise exception '%',why;end if;
 if t is not null then why:=private.trade_assignment_error(t,q.person_id,(s->>'id')::uuid);if why is not null then raise exception '%',why;end if;end if;
 original:=private.planning_shifts();
 select jsonb_agg(case when x->>'id'=s->>'id' then x||jsonb_build_object('person_id',q.payload->>'recipient') when x->>'id'=t->>'id' then x||jsonb_build_object('person_id',q.person_id) else x end order by x->>'id') into proposed from jsonb_array_elements(original) x;
 select array_agg(distinct w order by w) into weeks from (select private.planning_week((x->>'start')::timestamptz) w from jsonb_array_elements(jsonb_build_array(s)||case when t is null then '[]'::jsonb else jsonb_build_array(t) end) x union select private.planning_week((x->>'end')::timestamptz-interval '1 microsecond') from jsonb_array_elements(jsonb_build_array(s)||case when t is null then '[]'::jsonb else jsonb_build_array(t) end) x) z;
 a:=private.planning_assessment(proposed,weeks,array[q.person_id,q.payload->>'recipient']);b:=private.planning_assessment(original,weeks,array[q.person_id,q.payload->>'recipient']);
 return a||jsonb_build_object('fingerprint',md5((a->>'fingerprint')||q.version::text||q.payload::text),'before_hours',b->'hours','coverage_unchanged',a->'coverage'=b->'coverage','before',jsonb_build_array(s-'qualification_reason')||case when t is null then '[]'::jsonb else jsonb_build_array(t-'qualification_reason') end,'after',(select jsonb_agg(x-'qualification_reason') from jsonb_array_elements(proposed) x where x->>'id' in (s->>'id',t->>'id')));
end $$;
create function public.trade_options(p_shift uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s jsonb;people jsonb;trades jsonb;
begin
 if not private.scheduler_member() then raise exception 'Active workspace required';end if;
 s:=private.find_shift(p_shift);
 if s is null or s->>'person_id' is distinct from private.my_person() or (s->>'start')::timestamptz<=now() then raise exception 'Choose your own upcoming published shift';end if;
 if exists(select 1 from public.training_sessions where status='Scheduled' and (work_shift_id=p_shift or trainer_shift_id=p_shift)) or exists(select 1 from public.meetings where status='Scheduled' and (work_shift_id=p_shift or manager_shift_id=p_shift)) then raise exception 'Ask a manager to replan linked training or meetings first';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p,'name',private.person_name(p)) order by private.person_name(p)),'[]') into people from (select 's:'||id p from public.staff where active union select 'm:'||id::text from public.manager_profiles where active and on_roster and linked_staff_id is null) z where p<>s->>'person_id' and private.trade_assignment_error(s,p) is null;
 select coalesce(jsonb_agg(t-'qualification_reason' order by t->>'start'),'[]') into trades from private.published_shifts() t where t->>'person_id'<>s->>'person_id' and private.trade_assignment_error(s,t->>'person_id',(t->>'id')::uuid) is null and private.trade_assignment_error(t,s->>'person_id',p_shift) is null;
 return jsonb_build_object('source',s-'qualification_reason','people',people,'trades',trades);
end $$;
create function public.planning_read(p_week date,p_revision uuid default null,p_request uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_manager() then raise exception 'Manager access required';end if;
 if p_request is not null then return private.request_assessment(p_request);end if;
 if p_revision is not null then return private.revision_assessment(p_revision);end if;
 return private.planning_assessment(private.planning_shifts(),array[p_week]);
end $$;
create function public.coverage_read(p_week date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_manager() then raise exception 'Manager access required';end if;
 return jsonb_build_object('rules',(select to_jsonb(c) from private.coverage_rules c),'forecasts',(select coalesce(jsonb_agg(to_jsonb(f) order by day),'[]') from private.sales_forecasts f where day>=p_week and day<p_week+7),'periods',(select coalesce(jsonb_agg(to_jsonb(f) order by day),'[]') from private.period_forecasts f where day>=p_week and day<p_week+7),'overrides',(select coalesce(jsonb_agg(to_jsonb(o) order by day),'[]') from private.coverage_overrides o where day>=p_week and day<p_week+7),'can_configure',private.is_admin() or private.is_gm());
end $$;
create function private.validate_coverage_jobs(p_jobs jsonb) returns void language plpgsql stable security definer set search_path='' as $$
declare j record;
begin
 if jsonb_typeof(p_jobs) is distinct from 'object' or p_jobs='{}'::jsonb then raise exception 'Set job headcounts';end if;
 for j in select * from jsonb_each(p_jobs) loop
  if not exists(select 1 from public.training_positions where id=j.key::uuid and active) or j.value::text !~ '^[0-9]+$' or j.value::text::int>100 then raise exception 'Choose active jobs and whole-number headcounts from 0 to 100';end if;
 end loop;
end $$;
create function public.coverage_save(p_kind text,p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.scheduler_submissions;cfg private.coverage_rules;d jsonb;period jsonb;b jsonb;last_max numeric;total numeric;lunch numeric;dinner numeric;day_value date;v int;result jsonb;old jsonb;seen int[]:='{}';
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.is_manager() then raise exception 'Manager access required';end if;
 if p_submission is null then raise exception 'Submission required';end if;
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then if prior.actor<>auth.uid() or prior.action<>'coverage_'||p_kind or prior.payload<>p_payload then raise exception 'Submission changed';end if;return prior.result;end if;
 if p_kind='rules' then
  if not (private.is_admin() or private.is_gm()) then raise exception 'GM or IT must configure staffing rules';end if;
  select * into cfg from private.coverage_rules;
  if cfg.version is distinct from (p_payload->>'version')::int then raise exception 'Staffing rules changed. Reload';end if;
  if jsonb_typeof(p_payload->'days') is distinct from 'array' or jsonb_array_length(p_payload->'days')>7 then raise exception 'Configure up to seven weekdays';end if;
  for d in select value from jsonb_array_elements(p_payload->'days') loop
   if d->>'dow' is null or (d->>'dow')::int not between 0 and 6 or (d->>'dow')::int=any(seen) then raise exception 'Choose each weekday once';end if;seen:=array_append(seen,(d->>'dow')::int);
   if d->>'lunch_percent' is null or (d->>'lunch_percent')::numeric not between 0 and 100 then raise exception 'Set Lunch sales percentage from 0 to 100';end if;
   if jsonb_typeof(d->'periods') is distinct from 'array' or jsonb_array_length(d->'periods')<>2 or (select count(distinct x->>'name') from jsonb_array_elements(d->'periods') x where x->>'name' in ('Lunch','Dinner'))<>2 then raise exception 'Configure Lunch and Dinner';end if;
   for period in select value from jsonb_array_elements(d->'periods') loop
    if period->>'start' is null or period->>'end' is null or (period->>'start')::time=(period->>'end')::time then raise exception 'Set service window start and end';end if;
    if period->>'name'='Lunch' and ((period->>'start')::time>='16:00'::time or (period->>'end')::time<>'16:00'::time) or period->>'name'='Dinner' and ((period->>'start')::time<>'16:00'::time or (period->>'end')::time<='16:00'::time and (period->>'end')::time<>'00:00'::time) then raise exception 'Lunch ends and Dinner starts at 4 PM; Dinner ends by midnight';end if;
    if jsonb_typeof(period->'bands') is distinct from 'array' or jsonb_array_length(period->'bands')=0 then raise exception 'Set sales bands';end if;
    last_max:=0;
    for b in select value from jsonb_array_elements(period->'bands') loop
     if last_max is null or b->>'min' is null or (b->>'min')::numeric<>last_max or b->>'max' is not null and (b->>'max')::numeric<=last_max then raise exception 'Sales bands must start at zero without gaps or overlaps';end if;
     perform private.validate_coverage_jobs(b->'jobs');last_max:=(b->>'max')::numeric;
    end loop;
    if last_max is not null then raise exception 'The final sales band must have no upper limit';end if;
   end loop;
  end loop;
  old:=to_jsonb(cfg);update private.coverage_rules set days=p_payload->'days',version=version+1,updated_by=auth.uid() returning to_jsonb(coverage_rules) into result;
 elsif p_kind='forecast' then
  day_value:=(p_payload->>'day')::date;total:=(p_payload->>'total')::numeric;lunch:=(p_payload->>'lunch')::numeric;dinner:=(p_payload->>'dinner')::numeric;
  if total is null or lunch is null or dinner is null or total<0 or total>=1000000000 or lunch<0 or dinner<0 or lunch+dinner<>total or round(total,2)<>total or round(lunch,2)<>lunch or round(dinner,2)<>dinner then raise exception 'Lunch and Dinner must be nonnegative amounts adding up to the daily total';end if;
  select version,to_jsonb(f) into v,old from private.sales_forecasts f where day=day_value;
  if coalesce(v,0) is distinct from (p_payload->>'version')::int or coalesce((select version from private.period_forecasts where day=day_value),0) is distinct from (p_payload->>'period_version')::int then raise exception 'Forecast changed. Reload';end if;
  insert into private.sales_forecasts(day,amount) values(day_value,total) on conflict(day) do update set amount=excluded.amount,version=private.sales_forecasts.version+1;
  insert into private.period_forecasts(day,lunch,dinner) values(day_value,lunch,dinner) on conflict(day) do update set lunch=excluded.lunch,dinner=excluded.dinner,version=private.period_forecasts.version+1 returning to_jsonb(period_forecasts) into result;
 elsif p_kind='override' then
  day_value:=(p_payload->>'day')::date;
  select version,to_jsonb(o) into v,old from private.coverage_overrides o where day=day_value;
  if coalesce(v,0) is distinct from (p_payload->>'version')::int then raise exception 'Override changed. Reload';end if;
  if length(btrim(coalesce(p_payload->>'reason','')))<3 then raise exception 'Explain the date-specific target change';end if;
  if coalesce((p_payload->>'remove')::boolean,false) then delete from private.coverage_overrides where day=day_value;result:=jsonb_build_object('removed',true);
  else
   if jsonb_typeof(p_payload->'targets') is distinct from 'array' or jsonb_array_length(p_payload->'targets')<>2 or (select count(distinct x->>'name') from jsonb_array_elements(p_payload->'targets') x where x->>'name' in ('Lunch','Dinner'))<>2 then raise exception 'Set both Lunch and Dinner targets';end if;
   for period in select value from jsonb_array_elements(p_payload->'targets') loop perform private.validate_coverage_jobs(period->'jobs');end loop;
   insert into private.coverage_overrides(day,targets,reason,actor) values(day_value,p_payload->'targets',left(p_payload->>'reason',2000),auth.uid()) on conflict(day) do update set targets=excluded.targets,reason=excluded.reason,actor=excluded.actor,version=private.coverage_overrides.version+1 returning to_jsonb(coverage_overrides) into result;
  end if;
 else raise exception 'Unknown coverage action';end if;
 perform private.schedule_audit('coverage_'||p_kind,coalesce(day_value::text,'rules'),old,result);
 insert into private.scheduler_submissions values(p_submission,auth.uid(),'coverage_'||p_kind,p_payload,result);
 return result;
end $$;
-- Configuration edits hold already-reviewed queued schedules immediately. Legacy daily forecasts use the same trigger.
create function private.coverage_hold_queues() returns trigger language plpgsql security definer set search_path='' as $$
declare r record;d date;
begin
 perform pg_advisory_xact_lock(61902028);
 if TG_TABLE_NAME<>'coverage_rules' then d:=coalesce((to_jsonb(new)->>'day')::date,(to_jsonb(old)->>'day')::date);end if;
 for r in select rr.id,rr.version from private.schedule_revisions rr join private.schedule_weeks w on w.id=rr.week_id where rr.state='Queued' and (d is null or d between w.week_start and w.week_start+13) loop
  update private.schedule_revisions set state='Attention',error='Sales forecast or coverage targets changed. Review and schedule release again.',version=version+1 where id=r.id;
  perform private.notify_managers('release-attention:'||r.id||':'||r.version,'Coverage changed. Review the queued schedule again.');
 end loop;
 return coalesce(new,old);
end $$;
create trigger coverage_rules_changed after update on private.coverage_rules for each row execute function private.coverage_hold_queues();
create trigger period_forecast_changed after insert or update on private.period_forecasts for each row execute function private.coverage_hold_queues();
create trigger daily_forecast_changed after insert or update on private.sales_forecasts for each row execute function private.coverage_hold_queues();
create trigger coverage_override_changed after insert or update or delete on private.coverage_overrides for each row execute function private.coverage_hold_queues();
-- Remove obsolete account-type trade restrictions; the new wrapper checks assignment eligibility instead.
do $$declare definition text;begin
 definition:=pg_get_functiondef('private.scheduler_action_v1(text,jsonb,uuid)'::regprocedure);
 definition:=replace(definition,' or private.person_is_shl(recipient) is distinct from private.person_is_shl(p)','');
 definition:=replace(definition,'   if private.person_is_shl(q.person_id) is distinct from private.person_is_shl(private.my_person()) then raise exception ''This shift requires the same staff or SHL role'';end if;','');
 execute definition;
end $$;
alter function public.scheduler_action(text,jsonb,uuid) rename to scheduler_action_before_planning;
revoke all on function public.scheduler_action_before_planning(text,jsonb,uuid) from public,anon,authenticated;
create function public.scheduler_action(p_action text,p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.scheduler_submissions;a jsonb;v_result jsonb;q private.scheduler_requests;s jsonb;t jsonb;why text;recipient text;
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.scheduler_member() then raise exception 'Active workspace required';end if;
 if p_action in ('draft','save','review','release','queue','unqueue','rebase','roster','decide','revoke') and not private.is_manager() then raise exception 'Manager access required';end if;
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then
  if prior.actor<>auth.uid() or prior.action<>p_action or prior.payload<>p_payload then raise exception 'Submission changed';end if;
  return prior.result;
 end if;
 if p_action in ('release','queue') then
  if not private.is_manager() then raise exception 'Manager access required';end if;
  a:=private.revision_assessment((p_payload->>'id')::uuid);
  perform private.check_planning_review((p_payload->>'id')::uuid,'release',a,p_payload);
 end if;
 if p_action='request' and p_payload->>'kind' in ('Trade','Coverage','Offer') then
  -- Ownership and linked-assignment checks also apply to open offers.
  perform public.trade_options((p_payload->>'source_id')::uuid);
  s:=private.find_shift((p_payload->>'source_id')::uuid);
  if p_payload->>'kind'='Trade' then t:=private.find_shift((p_payload->>'target_id')::uuid);recipient:=t->>'person_id';else recipient:=p_payload->>'recipient';end if;
  if p_payload->>'kind'<>'Offer' then
   if recipient is null then raise exception 'Choose an eligible coworker';end if;
   why:=private.trade_assignment_error(s,recipient,(t->>'id')::uuid);if why is not null then raise exception '%',why;end if;
   if p_payload->>'kind'='Trade' then why:=private.trade_assignment_error(t,s->>'person_id',(s->>'id')::uuid);if why is not null then raise exception '%',why;end if;end if;
  end if;
 end if;
 if p_action in ('accept','decide') then
  select * into q from private.scheduler_requests where id=(p_payload->>'id')::uuid;
  if p_action='decide' and p_payload->>'decision'='Rejected' and length(btrim(coalesce(p_payload->>'response','')))<3 then raise exception 'Enter a reason for denying the request';end if;
  if q.kind in ('Trade','Coverage','Offer') then
   if p_action='accept' then
    s:=private.find_shift((q.payload->'source'->>'id')::uuid);t:=private.find_shift((q.payload->'target'->>'id')::uuid);
    why:=private.trade_assignment_error(s,private.my_person(),(t->>'id')::uuid);if why is not null then raise exception '%',why;end if;
    if q.kind='Trade' then why:=private.trade_assignment_error(t,q.person_id,(s->>'id')::uuid);if why is not null then raise exception '%',why;end if;end if;
   elsif p_payload->>'decision'='Approved' then
    if not private.is_manager() then raise exception 'Manager access required';end if;
    a:=private.request_assessment(q.id);perform private.check_planning_review(q.id,'request',a,p_payload);
   end if;
  end if;
 end if;
 v_result:=public.scheduler_action_before_planning(p_action,p_payload,p_submission);
 if p_action='review' then v_result:=v_result||jsonb_build_object('planning',private.revision_assessment((p_payload->>'id')::uuid));end if;
 -- The underlying action owns the idempotency record; save enriched review results too.
 update private.scheduler_submissions set result=v_result where id=p_submission;
 return v_result;
end $$;
-- Private helpers are never directly callable by web clients.
revoke all on function private.planning_week(timestamptz),private.planning_shifts(uuid),private.planning_assessment(jsonb,date[],text[]),private.revision_assessment(uuid),private.check_planning_review(uuid,text,jsonb,jsonb),private.release_revision(uuid),private.release_revision_before_planning(uuid),private.trade_assignment_error(jsonb,text,uuid),private.request_assessment(uuid),private.validate_coverage_jobs(jsonb),private.coverage_hold_queues() from public,anon,authenticated;
revoke all on function public.planning_read(date,uuid,uuid),public.coverage_read(date),public.coverage_save(text,jsonb,uuid),public.trade_options(uuid),public.scheduler_action(text,jsonb,uuid) from public,anon;
grant execute on function public.planning_read(date,uuid,uuid),public.coverage_read(date),public.coverage_save(text,jsonb,uuid),public.trade_options(uuid),public.scheduler_action(text,jsonb,uuid) to authenticated;
-- Existing queued releases have not acknowledged the new checks.
update private.schedule_revisions set state='Attention',error='New hours and coverage review required. Review and schedule release again.',version=version+1 where state='Queued';
commit;
