-- Shift workspace upgrade for a database at migrations 001–008. Apply once.
-- No live data is seeded. Preserve a fresh owner-controlled backup first.
begin;
-- 009_scheduler
-- Internal scheduler tables are exposed only through permission-checked projections/RPCs.
create table private.employee_accounts(id uuid primary key references auth.users(id),staff_id text unique not null references public.staff(id),active boolean not null default true,is_ca boolean not null default false,version int not null default 1);
alter table public.manager_profiles add column on_roster boolean not null default true;
create table private.schedule_weeks(id uuid primary key default gen_random_uuid(),week_start date unique not null check(extract(dow from week_start)=0),published_id uuid,draft_id uuid);
create table private.schedule_revisions(id uuid primary key default gen_random_uuid(),week_id uuid not null references private.schedule_weeks(id),state text not null default 'Draft' check(state in ('Draft','Queued','Published','Attention')),base_id uuid,shifts jsonb not null default '[]',version int not null default 1,release_at timestamptz,release_by uuid references auth.users(id),released_at timestamptz,error text,created_by uuid not null references auth.users(id),created_at timestamptz not null default now());
alter table private.schedule_weeks add foreign key(published_id) references private.schedule_revisions(id),add foreign key(draft_id) references private.schedule_revisions(id);
create table private.scheduler_requests(id uuid primary key default gen_random_uuid(),kind text not null check(kind in ('Availability','Time off','Trade','Coverage','Offer')),person_id text not null,created_by uuid not null references auth.users(id),status text not null default 'Pending' check(status in ('Pending','Accepted','Approved','Rejected','Withdrawn','Invalid')),payload jsonb not null,reason text not null default '',response text,version int not null default 1,claimed_by uuid references auth.users(id),decided_by uuid references auth.users(id),decided_at timestamptz,created_at timestamptz not null default now());
create table private.announcements(id uuid primary key default gen_random_uuid(),title text not null,body text not null,groups text[] not null default '{}',active boolean not null default true,version int not null default 1,created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table private.announcement_reads(user_id uuid references auth.users(id),announcement_id uuid references private.announcements(id),version int not null,primary key(user_id,announcement_id));
create table private.scheduler_notifications(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id),event_key text not null,body text not null,created_at timestamptz not null default now(),read_at timestamptz,unique(user_id,event_key));
create table private.scheduler_submissions(id uuid primary key,actor uuid not null,action text not null,payload jsonb not null,result jsonb not null);
create table private.scheduler_settings(id boolean primary key default true check(id),email_verified boolean not null default false,email_evidence text,last_worker_at timestamptz);
insert into private.scheduler_settings default values;
create table private.scheduler_audit(id bigint generated always as identity primary key,actor uuid,action text not null,record_id text,changed_at timestamptz not null default now(),before_value jsonb,after_value jsonb);
alter table private.employee_accounts enable row level security;
alter table private.schedule_weeks enable row level security;
alter table private.schedule_revisions enable row level security;
alter table private.scheduler_requests enable row level security;
alter table private.announcements enable row level security;
alter table private.announcement_reads enable row level security;
alter table private.scheduler_notifications enable row level security;
alter table private.scheduler_submissions enable row level security;
alter table private.scheduler_settings enable row level security;
alter table private.scheduler_audit enable row level security;
revoke all on all tables in schema private from public,anon,authenticated;

create function private.employee_staff() returns text language sql stable security definer set search_path='' as $$select a.staff_id from private.employee_accounts a join public.staff s on s.id=a.staff_id where a.id=auth.uid() and a.active and s.active$$;
create function private.is_ca() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from private.employee_accounts a join public.staff s on s.id=a.staff_id where a.id=auth.uid() and a.active and a.is_ca and s.active)$$;
create function private.scheduler_member() returns boolean language sql stable security definer set search_path='' as $$select private.is_manager() or private.employee_staff() is not null$$;
create function private.can_training() returns boolean language sql stable security definer set search_path='' as $$select private.is_manager() or private.is_ca()$$;
create function private.my_person() returns text language sql stable security definer set search_path='' as $$select case when private.is_manager() then 'm:'||auth.uid()::text else 's:'||private.employee_staff() end$$;
create function private.person_active(p_person text) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.staff where 's:'||id=p_person and active) or exists(select 1 from public.manager_profiles where 'm:'||id::text=p_person and active and on_roster)$$;
create function private.person_is_shl(p_person text) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.manager_profiles where active and 'm:'||id::text=p_person)$$;
create function private.person_name(p_person text) returns text language sql stable security definer set search_path='' as $$select coalesce((select first_name||' '||last_name from public.staff where 's:'||id=p_person),(select name from public.manager_profiles where 'm:'||id::text=p_person),'Former teammate')$$;
create function private.account_name(p_user uuid) returns text language sql stable security definer set search_path='' as $$select coalesce((select name from public.manager_profiles where id=p_user),(select s.first_name||' '||s.last_name from private.employee_accounts a join public.staff s on s.id=a.staff_id where a.id=p_user),'Former teammate')$$;
create function private.notify_person(p_person text,p_key text,p_body text) returns void language plpgsql security definer set search_path='' as $$begin
 insert into private.scheduler_notifications(user_id,event_key,body) select id,p_key,p_body from public.manager_profiles where 'm:'||id::text=p_person and active on conflict do nothing;
 insert into private.scheduler_notifications(user_id,event_key,body) select a.id,p_key,p_body from private.employee_accounts a join public.staff s on s.id=a.staff_id where 's:'||a.staff_id=p_person and a.active and s.active on conflict do nothing;
end $$;
create function private.notify_managers(p_key text,p_body text) returns void language sql security definer set search_path='' as $$insert into private.scheduler_notifications(user_id,event_key,body) select id,p_key,p_body from public.manager_profiles where active on conflict do nothing$$;
create function private.schedule_audit(p_action text,p_id text,p_before jsonb,p_after jsonb) returns void language sql security definer set search_path='' as $$insert into private.scheduler_audit(actor,action,record_id,before_value,after_value) values(auth.uid(),p_action,p_id,p_before,p_after)$$;
create function private.published_shifts() returns setof jsonb language sql stable security definer set search_path='' as $$select s from private.schedule_weeks w join private.schedule_revisions r on r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) s$$;
create function private.find_shift(p_id uuid,p_revision uuid default null) returns jsonb language sql stable security definer set search_path='' as $$select s from (select value s from private.schedule_revisions r cross join lateral jsonb_array_elements(r.shifts) where r.id=p_revision union all select * from private.published_shifts() where p_revision is null) q where s->>'id'=p_id::text limit 1$$;
-- Availability rows contain 7 weekday arrays of minute ranges. Omitted availability means unrestricted.
create function private.person_conflict(p_person text,p_start timestamptz,p_end timestamptz) returns text language plpgsql stable security definer set search_path='' as $$
declare d date; a jsonb; av_window jsonb; lo int; hi int; covered boolean; local_start timestamp:=p_start at time zone 'America/Chicago';local_end timestamp:=p_end at time zone 'America/Chicago';
begin
 if exists(select 1 from private.scheduler_requests where person_id=p_person and kind='Time off' and status='Approved' and (payload->>'start')::timestamptz<p_end and (payload->>'end')::timestamptz>p_start) then return 'Approved time off';end if;
 for d in select generate_series(local_start::date,local_end::date,interval '1 day')::date loop
  lo:=case when d=local_start::date then extract(hour from local_start)::int*60+extract(minute from local_start)::int else 0 end;
  hi:=case when d=local_end::date then extract(hour from local_end)::int*60+extract(minute from local_end)::int else 1440 end;
  if hi=lo then continue;end if;
  select payload into a from private.scheduler_requests where person_id=p_person and kind='Availability' and status='Approved' and (payload->>'effective')::date<=d order by (payload->>'effective')::date desc,created_at desc,id desc limit 1;
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

create function private.shift_issues(p_shifts jsonb,p_week date) returns text[] language plpgsql stable security definer set search_path='' as $$
declare issues text[]:='{}';s jsonb;o jsonb;t record;p text;starts timestamptz;ends timestamptz;job uuid;why text;seen text[]:='{}';
begin
 if jsonb_typeof(p_shifts) is distinct from 'array' or jsonb_array_length(p_shifts)>1000 then return array['A schedule must contain at most 1,000 shifts'];end if;
 for s in select value from jsonb_array_elements(p_shifts) loop
  begin
   perform (s->>'id')::uuid;p:=s->>'person_id';starts:=(s->>'start')::timestamptz;ends:=(s->>'end')::timestamptz;job:=(s->>'job_id')::uuid;
   if s->>'id' is null or p is null or starts is null or ends is null or s->>'slot' not in ('1','2') or s->>'slot' is null then raise exception 'Missing shift fields';end if;
   if s->>'id'=any(seen) then raise exception 'Duplicate shift ID';end if;seen:=array_append(seen,s->>'id');
   if ends<=starts or ends-starts>interval '24 hours' then raise exception 'Shift end must be after start and no more than 24 hours later';end if;
   if (starts at time zone 'America/Chicago')::date<p_week or (starts at time zone 'America/Chicago')::date>=p_week+7 then raise exception 'Shift must start in this scheduling week';end if;
   if exists(select 1 from private.schedule_weeks ww join private.schedule_revisions rr on rr.id=ww.published_id cross join lateral jsonb_array_elements(rr.shifts) xx where ww.week_start<>p_week and xx->>'id'=s->>'id') then raise exception 'Shift ID is already used in another week';end if;
   if not private.person_active(p) then raise exception 'Choose an active person on the work roster';end if;
   if left(p,2)='m:' then
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

alter table public.training_sessions drop constraint training_sessions_created_by_fkey;
alter table public.training_sessions add foreign key(created_by) references auth.users(id),add column ends_at timestamptz,add column work_shift_id uuid,add column trainer_shift_id uuid,add column schedule_revision_id uuid references private.schedule_revisions(id);
create function private.training_issues(p_shifts jsonb,p_week date,p_revision uuid) returns text[] language plpgsql stable security definer set search_path='' as $$
declare issues text[]:='{}';t record;s jsonb;tr jsonb;old_ids text[];
begin
 select array_agg(x->>'id') into old_ids from private.schedule_weeks w join private.schedule_revisions r on r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) x where w.week_start=p_week;
 for t in select * from public.training_sessions where status='Scheduled' and work_shift_id is not null and (schedule_revision_id=p_revision or (schedule_revision_id is null or exists(select 1 from private.schedule_revisions where id=schedule_revision_id and state='Published')) and (work_shift_id::text=any(coalesce(old_ids,'{}')) or trainer_shift_id::text=any(coalesce(old_ids,'{}')))) loop
  select value into s from jsonb_array_elements(p_shifts) where value->>'id'=t.work_shift_id::text;
  select value into tr from jsonb_array_elements(p_shifts) where value->>'id'=t.trainer_shift_id::text;
  if s is null and not t.work_shift_id::text=any(coalesce(old_ids,'{}')) then s:=private.find_shift(t.work_shift_id);end if;
  if tr is null and not t.trainer_shift_id::text=any(coalesce(old_ids,'{}')) then tr:=private.find_shift(t.trainer_shift_id);end if;
  if s is null or tr is null or s->>'person_id'<>'s:'||t.staff_id or tr->>'person_id'<>'s:'||t.trainer_id or (s->>'start')::timestamptz>t.scheduled_at or (s->>'end')::timestamptz<t.ends_at or (tr->>'start')::timestamptz>t.scheduled_at or (tr->>'end')::timestamptz<t.ends_at or (s->>'slot')::int<>t.shift then issues:=array_append(issues,'Adjust linked training for '||private.person_name('s:'||t.staff_id)||' before release');end if;
 end loop;return issues;
end $$;
create or replace function private.validate_training() returns trigger language plpgsql security definer set search_path='' as $$
declare s jsonb;t jsonb;draft_state text;link_required boolean;
begin
 perform pg_advisory_xact_lock(61902028);
 if TG_OP='UPDATE' then
  if new.id<>old.id or new.created_by<>old.created_by or new.created_at<>old.created_at then raise exception 'Training ownership cannot change';end if;
  if new.version<>old.version then raise exception 'Reload this training session before editing';end if;
  new.version:=old.version+1;
 end if;
 if exists(select 1 from private.schedule_revisions r cross join lateral jsonb_array_elements(r.shifts) x where r.state='Queued' and (r.id=new.schedule_revision_id or x->>'id' in (new.work_shift_id::text,new.trainer_shift_id::text,old.work_shift_id::text,old.trainer_shift_id::text))) then raise exception 'Cancel the queued schedule release before editing its training';end if;
 link_required:=TG_OP='INSERT' or old.work_shift_id is not null or new.work_shift_id is not null or new.trainer_shift_id is not null or new.scheduled_at is distinct from old.scheduled_at or new.staff_id is distinct from old.staff_id or new.trainer_id is distinct from old.trainer_id;
 if link_required and (new.work_shift_id is null or new.trainer_shift_id is null or new.ends_at is null) then raise exception 'Attach training to both work shifts and choose an end time';end if;
 if new.status='Scheduled' then
  if not exists(select 1 from public.staff where id=new.staff_id and active) then raise exception 'Choose an active employee';end if;
  if not exists(select 1 from public.staff where id=new.trainer_id and active and is_trainer) then raise exception 'Choose an active trainer';end if;
  if (TG_OP='INSERT' or new.scheduled_at is distinct from old.scheduled_at) and new.scheduled_at<now() then raise exception 'Choose a future start time';end if;
 end if;
 if new.status='Completed' and new.ends_at>now() then raise exception 'Training has not ended yet';end if;
 if new.work_shift_id is not null and new.status not in ('Cancelled','Missed') then
  if new.ends_at is null or new.ends_at<=new.scheduled_at then raise exception 'Training end must be after its start';end if;
  if new.schedule_revision_id is not null then
   select state into draft_state from private.schedule_revisions where id=new.schedule_revision_id;
   if draft_state is null then raise exception 'Schedule not found';end if;
   if draft_state<>'Published' and not private.is_manager() then raise exception 'CAs can schedule only against published work shifts';end if;
  end if;
  s:=private.find_shift(new.work_shift_id,case when draft_state in ('Draft','Attention') then new.schedule_revision_id else null end);
  t:=private.find_shift(new.trainer_shift_id,case when draft_state in ('Draft','Attention') then new.schedule_revision_id else null end);
  if t is null then t:=private.find_shift(new.trainer_shift_id);end if;
  if new.status='Scheduled' and (s is null or t is null or s->>'person_id'<>'s:'||new.staff_id or t->>'person_id'<>'s:'||new.trainer_id or (s->>'start')::timestamptz>new.scheduled_at or (s->>'end')::timestamptz<new.ends_at or (t->>'start')::timestamptz>new.scheduled_at or (t->>'end')::timestamptz<new.ends_at or (s->>'slot')::int<>new.shift) then raise exception 'Both people must be working throughout training, with the trainee’s Shift 1/2 designation';end if;
  if new.status='Scheduled' and exists(select 1 from public.training_sessions x where x.id<>new.id and x.status='Scheduled' and (x.trainer_id in (new.trainer_id,new.staff_id) or x.staff_id in (new.staff_id,new.trainer_id)) and x.scheduled_at<new.ends_at and coalesce(x.ends_at,x.scheduled_at+interval '1 minute')>new.scheduled_at) then raise exception 'A participant already has training at this time';end if;
 end if;
 new.updated_at:=now();return new;
end $$;
drop policy creators_add_training on public.training_sessions;
drop policy creators_edit_training on public.training_sessions;
create policy schedulers_add_training on public.training_sessions for insert to authenticated with check(private.can_training() and created_by=auth.uid());
create policy schedulers_edit_training on public.training_sessions for update to authenticated using(private.can_training() and created_by=auth.uid()) with check(private.can_training() and created_by=auth.uid());
create policy ca_read_training on public.training_sessions for select to authenticated using(private.is_ca() and (schedule_revision_id is null or exists(select 1 from private.schedule_revisions where id=schedule_revision_id and state='Published')));
-- Use an encapsulated helper in RLS: authenticated clients cannot read private revisions.
drop policy ca_read_training on public.training_sessions;
create function private.training_visible(p_revision uuid) returns boolean language sql stable security definer set search_path='' as $$select p_revision is null or exists(select 1 from private.schedule_revisions where id=p_revision and state='Published')$$;
create policy ca_read_training on public.training_sessions for select to authenticated using(private.is_ca() and private.training_visible(schedule_revision_id));
create policy ca_read_jobs on public.training_positions for select to authenticated using(private.is_ca());
create policy ca_read_signoffs on public.training_signoffs for select to authenticated using(private.is_ca());

create function private.training_draft_version() returns trigger language plpgsql security definer set search_path='' as $$begin
 update private.schedule_revisions set version=version+1 where id in (new.schedule_revision_id,old.schedule_revision_id) and state in ('Draft','Attention');return new;
end $$;
create trigger training_draft_version after insert or update on public.training_sessions for each row execute function private.training_draft_version();

create function private.release_revision(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r private.schedule_revisions;w private.schedule_weeks;issues text[];p text;old_shifts jsonb;result jsonb;
begin
 select * into r from private.schedule_revisions where id=p_id for update;
 select * into w from private.schedule_weeks where id=r.week_id for update;
 if r.state='Published' then return jsonb_build_object('state','Published','id',r.id);end if;
 if not exists(select 1 from public.manager_profiles where id=r.release_by and active) then issues:=array['The releasing manager no longer has access'];
 elsif w.published_id is distinct from r.base_id then issues:=array['The published schedule changed. Reload it and review your draft'];
 else issues:=private.shift_issues(r.shifts,w.week_start)||private.training_issues(r.shifts,w.week_start,r.id);end if;
 select shifts into old_shifts from private.schedule_revisions where id=w.published_id;
 if exists(select 1 from jsonb_array_elements(r.shifts) s where (s->>'start')::timestamptz<now() and not exists(select 1 from jsonb_array_elements(coalesce(old_shifts,'[]')) x where x=s)) then issues:=array_append(issues,'A new or changed shift has already started. Remove it from the draft and review again');end if;
 if cardinality(issues)>0 then
  update private.schedule_revisions set state='Attention',error=array_to_string(issues,E'\n'),version=version+1 where id=r.id;
  perform private.notify_managers('release-attention:'||r.id||':'||r.version,'Schedule for '||w.week_start||' needs attention: '||array_to_string(issues,'; '));
  return jsonb_build_object('state','Attention','issues',issues);
 end if;
 update private.schedule_revisions set state='Published',released_at=now(),error=null,version=version+1 where id=r.id;
 update private.schedule_weeks set published_id=r.id,draft_id=null where id=w.id;
 for p in select distinct x->>'person_id' from jsonb_array_elements(r.shifts||coalesce(old_shifts,'[]')) x loop
  perform private.notify_person(p,'schedule:'||r.id,'Your schedule for the week of '||w.week_start||' has been released or updated.');
 end loop;
 perform private.expire_shift_requests();
 perform private.schedule_audit('release',r.id::text,old_shifts,r.shifts);
 return jsonb_build_object('state','Published','id',r.id);
end $$;
create function private.expire_shift_requests() returns void language plpgsql security definer set search_path='' as $$
declare q private.scheduler_requests;s jsonb;t jsonb;
begin
 for q in select * from private.scheduler_requests where kind in ('Trade','Coverage','Offer') and status in ('Pending','Accepted') loop
  s:=private.find_shift((q.payload->'source'->>'id')::uuid);t:=private.find_shift((q.payload->'target'->>'id')::uuid);
  if s is null or s-'qualification_reason'<>q.payload->'source' or (s->>'start')::timestamptz<=now() or not private.person_active(q.person_id) or (q.kind='Trade' and (t is null or t-'qualification_reason'<>q.payload->'target' or (t->>'start')::timestamptz<=now())) then
   update private.scheduler_requests set status='Invalid',response='A referenced shift changed, started, or is no longer available',version=version+1 where id=q.id;
   perform private.notify_person(q.person_id,'invalid:'||q.id,'A shift request is no longer available. Check Requests for details.');
   if q.payload->>'recipient' is not null then perform private.notify_person(q.payload->>'recipient','invalid:'||q.id,'A shift request is no longer available. Check Requests for details.');end if;
   perform private.schedule_audit('invalidate_request',q.id::text,to_jsonb(q),(select to_jsonb(v) from private.scheduler_requests v where id=q.id));
  end if;
 end loop;
end $$;
create function private.run_schedule_releases() returns void language plpgsql security definer set search_path='' as $$
declare r record;
begin
 perform pg_advisory_xact_lock(61902028);
 for r in select id from private.schedule_revisions where state='Queued' and release_at<=now() order by release_at loop
  begin perform private.release_revision(r.id);
  exception when others then
   update private.schedule_revisions set error='Temporary release error: '||sqlerrm where id=r.id;
   perform private.notify_managers('release-error:'||r.id,'A scheduled release needs attention. The service will retry; the previous schedule is unchanged.');
  end;
 end loop;
 perform private.expire_shift_requests();
 update private.scheduler_settings set last_worker_at=now();
end $$;
create function public.scheduler_read(p_week date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;w private.schedule_weeks;r private.schedule_revisions;m boolean:=private.is_manager();ca boolean:=private.is_ca();v_staff_id text:=private.employee_staff();my_group text;my_person text:=private.my_person();
begin
 if not private.scheduler_member() then raise exception 'Your account needs active workspace access';end if;
 if extract(dow from p_week)<>0 then raise exception 'Choose a Sunday';end if;
 select * into w from private.schedule_weeks where week_start=p_week;
 if m then select * into r from private.schedule_revisions where id=w.draft_id;end if;
 my_group:=case when m then 'SHL' else (select department from public.staff where id=v_staff_id) end;
 result:=jsonb_build_object(
 'self',jsonb_build_object('id',auth.uid(),'person_id',my_person,'staff_id',v_staff_id,'name',private.account_name(auth.uid()),'is_manager',m,'is_ca',ca,'is_admin',private.is_admin()),
 'week',jsonb_build_object('start',p_week,'published_id',w.published_id,'draft',case when m and r.id is not null then to_jsonb(r)||jsonb_build_object('release_name',private.account_name(r.release_by)) else null end),
 'people',coalesce((select jsonb_agg(p order by p->>'name') from (
  select jsonb_build_object('id','s:'||s.id,'staff_id',s.id,'name',s.first_name||' '||s.last_name,'group',s.department,'primary_job_id',s.primary_job_id,'active',s.active,'is_trainer',s.is_trainer,'on_roster',true,'is_ca',exists(select 1 from private.employee_accounts a where a.staff_id=s.id and a.active and a.is_ca)) p from public.staff s where s.active or m or ca or exists(select 1 from private.published_shifts() z where z->>'person_id'='s:'||s.id)
  union all select jsonb_build_object('id','m:'||id,'name',name,'group','SHL','active',active,'on_roster',on_roster,'is_trainer',false,'version',version) from public.manager_profiles mp where active or m or exists(select 1 from private.published_shifts() z where z->>'person_id'='m:'||mp.id::text)) q),'[]'),
 'published',coalesce((select jsonb_agg(jsonb_build_object('week',wk.week_start,'revision_id',rr.id,'shifts',case when m then rr.shifts else (select coalesce(jsonb_agg(s-'qualification_reason'),'[]') from jsonb_array_elements(rr.shifts) s) end)) from private.schedule_weeks wk join private.schedule_revisions rr on rr.id=wk.published_id),'[]'),
 'jobs',coalesce((select jsonb_agg(to_jsonb(j)) from public.training_positions j),'[]'),
 'training',coalesce((select jsonb_agg(to_jsonb(t)) from public.training_sessions t where m or private.training_visible(t.schedule_revision_id) and (ca or t.staff_id=v_staff_id or t.trainer_id=v_staff_id)),'[]'),
 'signoffs',coalesce((select jsonb_agg(to_jsonb(f)) from public.training_signoffs f where m or ca or f.staff_id=v_staff_id),'[]'),
 'appointments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'scheduled_at',a.scheduled_at,'status',a.status,'type',a.type,'manager',p.name,'employee',s.first_name||' '||s.last_name)) from public.meetings a join public.manager_profiles p on p.id=a.manager_id join public.staff s on s.id=a.staff_id where a.staff_id=v_staff_id or a.manager_id=auth.uid()),'[]'),
 'requests',coalesce((select jsonb_agg(case when m or q.created_by=auth.uid() then to_jsonb(q)||jsonb_build_object('decided_name',case when q.decided_by is not null then private.account_name(q.decided_by) end) else to_jsonb(q)-'reason'-'response' end order by q.created_at desc) from private.scheduler_requests q where m or q.created_by=auth.uid() or q.claimed_by=auth.uid() or q.payload->>'recipient'=my_person or q.kind='Offer' and q.status='Pending'),'[]'),
 'announcements',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('author',private.account_name(a.created_by),'read',coalesce(rd.version=a.version,false)) order by a.created_at desc) from private.announcements a left join private.announcement_reads rd on rd.announcement_id=a.id and rd.user_id=auth.uid() where (a.active or a.created_by=auth.uid()) and (cardinality(a.groups)=0 or my_group=any(a.groups) or a.created_by=auth.uid())),'[]'),
 'announcement_history',coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'announcement_id',h.record_id,'at',h.changed_at,'value',h.after_value) order by h.id desc) from private.scheduler_audit h join private.announcements a on a.id::text=h.record_id where h.action='announcement' and a.created_by=auth.uid()),'[]'),
 'notifications',coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (select * from private.scheduler_notifications where user_id=auth.uid() order by created_at desc limit 100) n),'[]'),
 'accounts',case when m then coalesce((select jsonb_agg(to_jsonb(a)) from private.employee_accounts a),'[]') else '[]'::jsonb end,
 'service',case when m then (select to_jsonb(s) from private.scheduler_settings s) else '{}'::jsonb end,
 'releases',case when m then coalesce((select jsonb_agg(jsonb_build_object('id',rev.id,'week',wk.week_start,'state',rev.state,'release_at',rev.release_at,'error',rev.error,'release_name',private.account_name(rev.release_by))) from private.schedule_revisions rev join private.schedule_weeks wk on wk.id=rev.week_id where rev.state in ('Queued','Attention')),'[]') else '[]'::jsonb end,
 'audit',case when m then coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('actor_name',private.account_name(a.actor))) from (select * from private.scheduler_audit order by id desc limit 100) a),'[]') else '[]'::jsonb end);
 return result;
end $$;

-- A single transaction serializes all scheduling/request mutations, including cron.
create function public.scheduler_action(p_action text,p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
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
    new_shifts:=p_payload->'shifts';issues:=private.shift_issues(new_shifts,w.week_start);
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

-- Only the authenticated invitation service links a newly created employee account.
create function public.link_employee_account(p_actor uuid,p_user uuid,p_staff text,p_submission uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(61902028);
 if not exists(select 1 from public.manager_profiles where id=p_actor and active) or not (select email_verified from private.scheduler_settings) then raise exception 'Manager access and verified email delivery required';end if;
 if not exists(select 1 from public.staff where id=p_staff and active) or exists(select 1 from public.manager_profiles where id=p_user) then raise exception 'Choose an active employee without a manager account';end if;
 if exists(select 1 from private.employee_accounts where id=p_user and staff_id=p_staff) then return;end if;
 insert into private.employee_accounts(id,staff_id) values(p_user,p_staff);
 insert into private.scheduler_audit(actor,action,record_id,after_value) values(p_actor,'invite_employee',p_staff,jsonb_build_object('user_id',p_user,'submission',p_submission));
end $$;
create function public.employee_invitation_check(p_staff text) returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not private.is_manager() then raise exception 'Manager access required';end if;
 if not (select email_verified from private.scheduler_settings) then raise exception 'Employee invitations are disabled until email delivery is verified';end if;
 if exists(select 1 from private.employee_accounts where staff_id=p_staff) then raise exception 'This employee already has an account';end if;
 if not exists(select 1 from public.staff where id=p_staff and active) then raise exception 'Choose an active employee';end if;
 return jsonb_build_object('name',private.person_name('s:'||p_staff));end $$;
create table private.employee_invitations(id uuid primary key,actor uuid not null references auth.users(id),staff_id text not null unique references public.staff(id),email text not null unique,status text not null default 'Reserved',user_id uuid references auth.users(id),error text,created_at timestamptz not null default now());
alter table private.employee_invitations enable row level security;
revoke all on private.employee_invitations from public,anon,authenticated;
create function public.reserve_employee_invitation(p_staff text,p_email text,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare job private.employee_invitations;details jsonb;
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.is_manager() then raise exception 'Manager access required';end if;
 select * into job from private.employee_invitations where id=p_submission;
 if found then
  if job.actor<>auth.uid() or job.staff_id<>p_staff or job.email<>lower(trim(p_email)) then raise exception 'Invitation submission changed';end if;
  return jsonb_build_object('fresh',false,'status',job.status,'error',job.error);
 end if;
 details:=public.employee_invitation_check(p_staff);
 if p_submission is null or p_email is null or length(p_email)>254 or p_email!~'^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Provide a valid email and submission';end if;
 if exists(select 1 from private.employee_invitations where staff_id=p_staff or email=lower(trim(p_email))) then raise exception 'An invitation already exists for this person or address. IT must review its status before sending another';end if;
 insert into private.employee_invitations(id,actor,staff_id,email) values(p_submission,auth.uid(),p_staff,lower(trim(p_email)));
 return details||jsonb_build_object('fresh',true);
end $$;
create function public.finish_employee_invitation(p_submission uuid,p_user uuid,p_error text default null) returns void language plpgsql security definer set search_path='' as $$
declare job private.employee_invitations;
begin
 perform pg_advisory_xact_lock(61902028);select * into job from private.employee_invitations where id=p_submission for update;
 if not found then raise exception 'Invitation reservation not found';end if;
 if job.status='Linked' then return;end if;
 if p_user is null then update private.employee_invitations set status='Needs attention',error=left(p_error,1000) where id=job.id;return;end if;
 perform public.link_employee_account(job.actor,p_user,job.staff_id,job.id);
 update private.employee_invitations set status='Linked',user_id=p_user,error=null where id=job.id;
end $$;
revoke all on function public.reserve_employee_invitation(text,text,uuid) from public,anon;
grant execute on function public.reserve_employee_invitation(text,text,uuid) to authenticated;
revoke all on function public.finish_employee_invitation(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.finish_employee_invitation(uuid,uuid,text) to service_role;

-- No private function is callable by anonymous users; explicitly expose only policy predicates.
revoke execute on all functions in schema private from public,anon,authenticated;
grant execute on function private.is_manager(),private.is_admin(),private.is_gm(),private.is_ca(),private.can_training(),private.training_visible(uuid) to authenticated;
revoke all on function public.scheduler_read(date),public.scheduler_action(text,jsonb,uuid),public.employee_invitation_check(text) from public,anon;
grant execute on function public.scheduler_read(date),public.scheduler_action(text,jsonb,uuid),public.employee_invitation_check(text) to authenticated;
revoke all on function public.link_employee_account(uuid,uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.link_employee_account(uuid,uuid,text,uuid) to service_role;
update public.manager_profiles set on_roster=false where is_admin and not is_gm;


-- Flush deferred validation before subsequent table changes, retaining atomic installation.
set constraints all immediate;
set constraints all deferred;

-- 011_workspaces_requests
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


-- Flush deferred validation before subsequent table changes, retaining atomic installation.
set constraints all immediate;
set constraints all deferred;

-- 012_operations
create table private.person_contacts(person_id text primary key,phone text not null default '',email text not null default '',share_phone boolean not null default false,share_email boolean not null default false,emergency_name text not null default '',emergency_phone text not null default '',birthday_month int,birthday_day int,version int not null default 1,check((birthday_month is null and birthday_day is null) or (birthday_month between 1 and 12 and birthday_day between 1 and 31)));
create table private.logbook(id uuid primary key default gen_random_uuid(),title text not null,body text not null default '',category text not null default 'Handover',entry_date date not null default ((now() at time zone 'America/Chicago')::date),assigned_to uuid references public.manager_profiles(id),due_on date,completed_at timestamptz,created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),version int not null default 1,archived boolean not null default false);
create table private.documents(id uuid primary key default gen_random_uuid(),title text not null,category text not null default 'Handbook',groups text[] not null default '{}',active boolean not null default true,created_by uuid not null references auth.users(id),version int not null default 1,created_at timestamptz not null default now());
create table private.document_versions(id uuid primary key default gen_random_uuid(),document_id uuid not null references private.documents(id),version int not null,path text unique not null,filename text not null,ready boolean not null default false,created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),unique(document_id,version));
create table private.document_activity(id bigint generated always as identity primary key,document_id uuid not null references private.documents(id),version int not null,user_id uuid not null references auth.users(id),kind text not null check(kind in ('Opened','Downloaded','Read')),created_at timestamptz not null default now());
create table private.pay_rates(id uuid primary key default gen_random_uuid(),person_id text not null,effective date not null,hourly_rate numeric(10,2) not null check(hourly_rate>=0 and hourly_rate<100000),version int not null default 1,unique(person_id,effective));
create table private.sales_forecasts(day date primary key,amount numeric(14,2) not null check(amount>=0 and amount<1000000000),version int not null default 1);
create table private.calendar_tokens(user_id uuid primary key references auth.users(id),token_hash text unique not null,created_at timestamptz not null default now());
alter table private.person_contacts enable row level security;
alter table private.logbook enable row level security;
alter table private.documents enable row level security;
alter table private.document_versions enable row level security;
alter table private.document_activity enable row level security;
alter table private.pay_rates enable row level security;
alter table private.sales_forecasts enable row level security;
alter table private.calendar_tokens enable row level security;
revoke all on private.person_contacts,private.logbook,private.documents,private.document_versions,private.document_activity,private.pay_rates,private.sales_forecasts,private.calendar_tokens from public,anon,authenticated;
create function private.document_allowed(p_document uuid) returns boolean language sql stable security definer set search_path='' as $$
 select private.scheduler_member() and exists(select 1 from private.documents d where d.id=p_document and (private.is_manager() or d.active and (cardinality(d.groups)=0 or case when private.is_manager() then 'SHL' else (select department from public.staff where id=private.employee_staff()) end=any(d.groups))))
$$;
create function public.operations_read(p_module text,p_view text,p_offset int default 0,p_search text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare manager boolean:=p_view<>'employee' and private.is_manager();items jsonb;total bigint;person text:=private.my_person();g text;own_contact jsonb;
begin
 if not private.scheduler_member() then raise exception 'Active workspace access required';end if;
 if p_view not in ('employee','manager','it') or p_view is null or p_view='manager' and not private.is_manager() or p_view='it' and not private.is_admin() then raise exception 'Workspace access required';end if;
 if p_offset<0 or p_offset is null then raise exception 'Invalid page';end if;
 if p_module in ('logbook','labor','reports','brief') and not manager then raise exception 'Manager workspace required';end if;
 if p_module='directory' then
  select count(*) into total from (select 's:'||id id,first_name||' '||last_name name from public.staff where active union all select 'm:'||id::text,name from public.manager_profiles where active and on_roster and linked_staff_id is null) x where x.name ilike '%'||p_search||'%';
  select coalesce(jsonb_agg(v),'[]') into items from (select jsonb_build_object('person_id',x.id,'name',x.name,'group',x.g,'job',x.job,'trainer',x.trainer,'version',case when x.id=person then coalesce(c.version,0) end,'phone',case when manager or x.id=person or c.share_phone then c.phone end,'email',case when manager or x.id=person or c.share_email then c.email end,'share_phone',case when x.id=person then coalesce(c.share_phone,false) end,'share_email',case when x.id=person then coalesce(c.share_email,false) end,'emergency_name',case when manager or x.id=person then c.emergency_name end,'emergency_phone',case when manager or x.id=person then c.emergency_phone end,'birthday_month',c.birthday_month,'birthday_day',c.birthday_day) v from (select 's:'||s.id id,s.first_name||' '||s.last_name name,case when private.person_is_shl('s:'||s.id) then 'SHL' else s.department end g,case when private.person_is_shl('s:'||s.id) then 'SHL' else j.name end job,s.is_trainer trainer from public.staff s left join public.training_positions j on j.id=s.primary_job_id where s.active union all select 'm:'||id::text,name,'SHL',null,false from public.manager_profiles where active and on_roster and linked_staff_id is null) x left join private.person_contacts c on c.person_id=x.id where x.name ilike '%'||p_search||'%' order by x.name,x.id limit 50 offset p_offset) z;
 elsif p_module='brief' then
  return jsonb_build_object('appointments',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'scheduled_at',a.scheduled_at,'employee',s.first_name||' '||s.last_name,'manager',m.name,'type',a.type) order by a.scheduled_at),'[]') from public.meetings a join public.staff s on s.id=a.staff_id join public.manager_profiles m on m.id=a.manager_id where a.status='Scheduled' and (a.scheduled_at at time zone 'America/Chicago')::date=(now() at time zone 'America/Chicago')::date),'reminders',(select coalesce(jsonb_agg(to_jsonb(l)||jsonb_build_object('assignee',private.account_name(l.assigned_to))),'[]') from private.logbook l where not l.archived and l.completed_at is null and l.due_on<=(now() at time zone 'America/Chicago')::date),'birthdays',(select coalesce(jsonb_agg(jsonb_build_object('name',private.person_name(c.person_id))),'[]') from private.person_contacts c where private.person_active(c.person_id) and c.birthday_month=extract(month from now() at time zone 'America/Chicago') and c.birthday_day=extract(day from now() at time zone 'America/Chicago')));
 elsif p_module='profile' then
  select to_jsonb(c) into own_contact from private.person_contacts c where c.person_id=person;
  return jsonb_build_object('profile',coalesce(own_contact,jsonb_build_object('person_id',person,'version',0)),'calendar_enabled',exists(select 1 from private.calendar_tokens where user_id=auth.uid()));
 elsif p_module='logbook' then
  select count(*) into total from private.logbook where not archived and (title||' '||body) ilike '%'||p_search||'%';
  select coalesce(jsonb_agg(v),'[]') into items from (select to_jsonb(l)||jsonb_build_object('author',private.account_name(l.created_by),'assignee',private.account_name(l.assigned_to),'history',(select coalesce(jsonb_agg(jsonb_build_object('at',a.changed_at,'by',private.account_name(a.actor),'action',a.action,'before',a.before_value,'after',a.after_value)),'[]') from (select * from private.scheduler_audit where record_id=l.id::text and action like 'operations:logbook%' order by id desc limit 30) a)) v from private.logbook l where not archived and (title||' '||body) ilike '%'||p_search||'%' order by entry_date desc,created_at desc,id limit 50 offset p_offset) z;
 elsif p_module='documents' then
  g:=case when private.is_manager() then 'SHL' else (select department from public.staff where id=private.employee_staff()) end;
  select count(*) into total from private.documents d where (manager or d.active and (cardinality(d.groups)=0 or g=any(d.groups))) and d.title ilike '%'||p_search||'%';
  select coalesce(jsonb_agg(v),'[]') into items from (select to_jsonb(d)||jsonb_build_object('file',(select to_jsonb(f) from private.document_versions f where f.document_id=d.id and f.version=d.version),'read',exists(select 1 from private.document_activity a where a.document_id=d.id and a.version=d.version and a.user_id=auth.uid() and a.kind='Read'),'history',case when manager then (select coalesce(jsonb_agg(to_jsonb(h) order by h.version desc),'[]') from private.document_versions h where h.document_id=d.id) else '[]'::jsonb end,'activity',case when manager then (select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('name',private.account_name(a.user_id))),'[]') from (select * from private.document_activity where document_id=d.id order by id desc limit 100) a) else '[]'::jsonb end) v from private.documents d where (manager or d.active and (cardinality(d.groups)=0 or g=any(d.groups))) and d.title ilike '%'||p_search||'%' order by d.created_at desc,d.id limit 50 offset p_offset) z;
 elsif p_module='labor' then
  return jsonb_build_object('rates',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from private.pay_rates r),'forecasts',(select coalesce(jsonb_agg(to_jsonb(f)),'[]') from private.sales_forecasts f),'can_edit_rates',private.is_admin() or private.is_gm());
 elsif p_module='reports' then
  return jsonb_build_object('meetings',(select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.id,'name',s.first_name||' '||s.last_name,'group',s.department,'last_completed',m.last_completed,'due_on',case when m.last_completed is null then null else (m.last_completed+interval '6 months')::date end)),'[]') from public.staff s left join lateral (select max(completed_on) last_completed from public.meetings where staff_id=s.id and status='Completed') m on true where s.active and not exists(select 1 from public.manager_profiles mp where mp.active and mp.linked_staff_id=s.id)));
 else raise exception 'Unknown module';end if;
 return jsonb_build_object('items',items,'total',total,'offset',p_offset,'limit',50);
end $$;
create function public.operations_action(p_action text,p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.scheduler_submissions;result jsonb:='{}';before_value jsonb;after_value jsonb;c private.person_contacts;l private.logbook;d private.documents;r private.pay_rates;f private.sales_forecasts;person text:=private.my_person();file_id uuid;path text;token text;birth_month int;birth_day int;
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.scheduler_member() then raise exception 'Active workspace access required';end if;
 if p_submission is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Submission information required';end if;
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then if prior.actor<>auth.uid() or prior.action<>'operations:'||p_action or prior.payload<>p_payload then raise exception 'Submission changed. Reload';end if;return prior.result;end if;
 if p_action in ('logbook_save','logbook_complete','document_save','forecast_save') and not private.is_manager() then raise exception 'Manager access required';end if;
 if p_action='profile_save' then
  select * into c from private.person_contacts where person_id=person;
  if p_payload->>'version' is null or coalesce(c.version,0)<>(p_payload->>'version')::int then raise exception 'Your profile changed. Reload';end if;
  before_value:=to_jsonb(c);birth_month:=nullif(p_payload->>'birthday_month','')::int;birth_day:=nullif(p_payload->>'birthday_day','')::int;
  if (birth_month is null)<>(birth_day is null) then raise exception 'Choose both birthday month and day, or leave both blank';end if;
  if birth_month is not null then perform make_date(2000,birth_month,birth_day);end if;
  insert into private.person_contacts(person_id,phone,email,share_phone,share_email,emergency_name,emergency_phone,birthday_month,birthday_day) values(person,left(coalesce(p_payload->>'phone',''),80),left(coalesce(p_payload->>'email',''),254),coalesce((p_payload->>'share_phone')::boolean,false),coalesce((p_payload->>'share_email')::boolean,false),left(coalesce(p_payload->>'emergency_name',''),160),left(coalesce(p_payload->>'emergency_phone',''),80),birth_month,birth_day) on conflict(person_id) do update set phone=excluded.phone,email=excluded.email,share_phone=excluded.share_phone,share_email=excluded.share_email,emergency_name=excluded.emergency_name,emergency_phone=excluded.emergency_phone,birthday_month=excluded.birthday_month,birthday_day=excluded.birthday_day,version=private.person_contacts.version+1 returning to_jsonb(person_contacts) into after_value;
 elsif p_action in ('logbook_save','logbook_complete') then
  if p_payload->>'id' is not null then select * into l from private.logbook where id=(p_payload->>'id')::uuid; if l.id is null or p_payload->>'version' is null or l.version<>(p_payload->>'version')::int then raise exception 'This entry changed. Reload';end if;end if;
  before_value:=to_jsonb(l);
  if p_action='logbook_complete' then
   if l.id is null or auth.uid() not in (l.created_by,coalesce(l.assigned_to,l.created_by)) then raise exception 'Only the author or assigned manager can complete this task';end if;
   update private.logbook set completed_at=case when coalesce((p_payload->>'completed')::boolean,true) then now() end,version=version+1 where id=l.id returning to_jsonb(logbook) into after_value;
  else
   if l.id is not null and l.created_by<>auth.uid() then raise exception 'Only the author can edit this entry';end if;
   if length(trim(coalesce(p_payload->>'title','')))=0 then raise exception 'Enter a title';end if;
   if nullif(p_payload->>'assigned_to','') is not null and not exists(select 1 from public.manager_profiles where id=(p_payload->>'assigned_to')::uuid and active) then raise exception 'Choose an active manager';end if;
   insert into private.logbook(id,title,body,category,entry_date,assigned_to,due_on,created_by,archived) values(coalesce(l.id,gen_random_uuid()),left(trim(p_payload->>'title'),160),left(coalesce(p_payload->>'body',''),10000),left(coalesce(p_payload->>'category','Handover'),60),(p_payload->>'entry_date')::date,nullif(p_payload->>'assigned_to','')::uuid,nullif(p_payload->>'due_on','')::date,auth.uid(),coalesce((p_payload->>'archived')::boolean,false)) on conflict(id) do update set title=excluded.title,body=excluded.body,category=excluded.category,entry_date=excluded.entry_date,assigned_to=excluded.assigned_to,due_on=excluded.due_on,archived=excluded.archived,version=private.logbook.version+1 returning to_jsonb(logbook) into after_value;
  end if;
 elsif p_action='document_save' then
  if p_payload->>'id' is not null then select * into d from private.documents where id=(p_payload->>'id')::uuid;if d.id is null or p_payload->>'version' is null or d.version<>(p_payload->>'version')::int then raise exception 'This document changed. Reload';end if;end if;
  before_value:=to_jsonb(d);
  if length(trim(coalesce(p_payload->>'title','')))=0 then raise exception 'Enter a document title';end if;
  if exists(select 1 from jsonb_array_elements_text(p_payload->'groups') g where g not in ('FOH','BOH','Catering','SHL')) then raise exception 'Choose valid position groups';end if;
  if not coalesce((p_payload->>'archive')::boolean,false) and length(coalesce(p_payload->>'filename',''))=0 then raise exception 'Choose a file for this version';end if;
  insert into private.documents(id,title,category,groups,created_by,active) values(coalesce(d.id,gen_random_uuid()),left(p_payload->>'title',160),left(coalesce(p_payload->>'category','Handbook'),60),array(select jsonb_array_elements_text(p_payload->'groups')),auth.uid(),not coalesce((p_payload->>'archive')::boolean,false)) on conflict(id) do update set title=excluded.title,category=excluded.category,groups=excluded.groups,active=excluded.active,version=private.documents.version+1 returning * into d;
  after_value:=to_jsonb(d);
  if d.active then
   file_id:=gen_random_uuid();path:=d.id::text||'/'||file_id::text;
   insert into private.document_versions(id,document_id,version,path,filename,created_by) values(file_id,d.id,d.version,path,left(p_payload->>'filename',255),auth.uid());
   result:=jsonb_build_object('id',d.id,'file_id',file_id,'path',path);
  end if;
 elsif p_action='document_activity' then
  select * into d from private.documents where id=(p_payload->>'id')::uuid;
  if not private.document_allowed(d.id) or not d.active or not exists(select 1 from private.document_versions where document_id=d.id and version=d.version and ready) then raise exception 'Document unavailable';end if;
  if p_payload->>'version' is null or d.version<>(p_payload->>'version')::int then raise exception 'Document changed. Open the current version';end if;
  if p_payload->>'kind' not in ('Opened','Downloaded','Read') or p_payload->>'kind' is null then raise exception 'Unknown document activity';end if;
  insert into private.document_activity(document_id,version,user_id,kind) values(d.id,d.version,auth.uid(),p_payload->>'kind');
 elsif p_action='rate_save' then
  if not (private.is_admin() or private.is_gm()) then raise exception 'GM or IT access required to maintain rates';end if;
  if not private.person_active(p_payload->>'person_id') then raise exception 'Choose an active rostered person';end if;
  select * into r from private.pay_rates where person_id=p_payload->>'person_id' and effective=(p_payload->>'effective')::date;
  if p_payload->>'version' is null or coalesce(r.version,0)<>(p_payload->>'version')::int then raise exception 'This rate changed. Reload';end if;
  before_value:=to_jsonb(r);
  insert into private.pay_rates(person_id,effective,hourly_rate) values(p_payload->>'person_id',(p_payload->>'effective')::date,(p_payload->>'hourly_rate')::numeric) on conflict(person_id,effective) do update set hourly_rate=excluded.hourly_rate,version=private.pay_rates.version+1 returning to_jsonb(pay_rates) into after_value;
 elsif p_action='forecast_save' then
  select * into f from private.sales_forecasts where day=(p_payload->>'day')::date;
  if p_payload->>'version' is null or coalesce(f.version,0)<>(p_payload->>'version')::int then raise exception 'Forecast changed. Reload';end if;
  before_value:=to_jsonb(f);
  insert into private.sales_forecasts(day,amount) values((p_payload->>'day')::date,(p_payload->>'amount')::numeric) on conflict(day) do update set amount=excluded.amount,version=private.sales_forecasts.version+1 returning to_jsonb(sales_forecasts) into after_value;
 elsif p_action='calendar_create' then
  token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into private.calendar_tokens(user_id,token_hash) values(auth.uid(),encode(sha256(convert_to(token,'UTF8')),'hex')) on conflict(user_id) do update set token_hash=excluded.token_hash,created_at=now();
  result:=jsonb_build_object('token',token);
 elsif p_action='calendar_revoke' then delete from private.calendar_tokens where user_id=auth.uid();
 else raise exception 'Unknown operation';end if;
 if before_value is not null or after_value is not null then perform private.schedule_audit('operations:'||p_action,coalesce(after_value->>'id',person),before_value,after_value);end if;
 insert into private.scheduler_submissions(id,actor,action,payload,result) values(p_submission,auth.uid(),'operations:'||p_action,p_payload,result);
 return result;
end $$;
revoke all on function private.document_allowed(uuid) from public,anon;
grant execute on function private.document_allowed(uuid) to authenticated;
revoke all on function public.operations_read(text,text,int,text),public.operations_action(text,jsonb,uuid) from public,anon;
grant execute on function public.operations_read(text,text,int,text),public.operations_action(text,jsonb,uuid) to authenticated;
alter function private.run_schedule_releases() rename to run_schedule_releases_v1;
create function private.run_schedule_releases() returns void language plpgsql security definer set search_path='' as $$
declare d date:=(now() at time zone 'America/Chicago')::date;l record;c record;
begin
 perform private.run_schedule_releases_v1();
 if (now() at time zone 'America/Chicago')::time<'06:00' then return;end if;
 for l in select * from private.logbook where not archived and completed_at is null and due_on<=d loop
  if l.assigned_to is not null then
   insert into private.scheduler_notifications(user_id,event_key,body) select l.assigned_to,'reminder:'||l.id||':'||d,'Follow-up due: '||l.title where exists(select 1 from public.manager_profiles where id=l.assigned_to and active) on conflict do nothing;
  else perform private.notify_managers('reminder:'||l.id||':'||d,'Follow-up due: '||l.title);end if;
 end loop;
 for c in select * from private.person_contacts where birthday_month=extract(month from d) and birthday_day=extract(day from d) and private.person_active(person_id) loop
  perform private.notify_managers('birthday:'||c.person_id||':'||d,'Birthday today: '||private.person_name(c.person_id));
 end loop;
end $$;
revoke all on function private.run_schedule_releases(),private.run_schedule_releases_v1() from public,anon,authenticated;


-- Flush deferred validation before subsequent table changes, retaining atomic installation.
set constraints all immediate;
set constraints all deferred;

-- 013_document_storage
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('shift-documents','shift-documents',false,10485760,array['application/pdf','text/plain','image/png','image/jpeg','application/vnd.openxmlformats-officedocument.wordprocessingml.document']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create function private.document_file_access(p_path text,p_write boolean) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.document_versions f join private.documents d on d.id=f.document_id where f.path=p_path and case when p_write then private.is_manager() and f.created_by=auth.uid() and not f.ready and d.version=f.version and d.active else private.document_allowed(d.id) and f.ready and (private.is_manager() or d.active and d.version=f.version) end)
$$;
revoke all on function private.document_file_access(text,boolean) from public,anon;
grant execute on function private.document_file_access(text,boolean) to authenticated;
create policy shift_documents_read on storage.objects for select to authenticated using(bucket_id='shift-documents' and private.document_file_access(name,false));
create policy shift_documents_upload on storage.objects for insert to authenticated with check(bucket_id='shift-documents' and private.document_file_access(name,true));
create function public.document_ready(p_file uuid) returns void language plpgsql security definer set search_path='' as $$
declare f private.document_versions;
begin
 perform pg_advisory_xact_lock(61902028);
 select * into f from private.document_versions where id=p_file;
 if not private.is_manager() or f.id is null or f.created_by<>auth.uid() then raise exception 'File access denied';end if;
 if not exists(select 1 from storage.objects where bucket_id='shift-documents' and name=f.path) then raise exception 'Upload has not completed. Retry the upload';end if;
 if not exists(select 1 from private.documents where id=f.document_id and version=f.version and active) then raise exception 'A newer document version exists. Reload the library';end if;
 if not f.ready then
  update private.document_versions set ready=true where id=f.id;
  perform private.schedule_audit('document_published',f.document_id::text,null,jsonb_build_object('version',f.version,'filename',f.filename));
 end if;
end $$;
revoke all on function public.document_ready(uuid) from public,anon;
grant execute on function public.document_ready(uuid) to authenticated;


-- Flush deferred validation before subsequent table changes, retaining atomic installation.
set constraints all immediate;
set constraints all deferred;

-- 014_calendar_feed
-- The edge endpoint supplies a bearer subscription token, never a user ID.
create function public.calendar_feed_data(p_token text) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
  select jsonb_build_object('uid','shift-'||(x->>'id'),'start',x->>'start','end',x->>'end','title','Work · '||coalesce(j.name,'SHL')||' · Shift '||(x->>'slot'),'status','CONFIRMED','sequence',(select count(*) from private.schedule_revisions z where z.week_id=w.id and z.state='Published'),'updated',r.released_at) e
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
revoke all on function public.calendar_feed_data(text) from public,anon,authenticated;
grant execute on function public.calendar_feed_data(text) to service_role;
create function private.revoke_disabled_calendar() returns trigger language plpgsql security definer set search_path='' as $$begin
 if old.active and not new.active then
  if tg_table_name='staff' then delete from private.calendar_tokens where user_id in (select id from private.employee_accounts where staff_id=new.id);
  else delete from private.calendar_tokens where user_id=new.id;end if;
 end if;return new;
end $$;
create trigger disable_calendar_staff after update of active on public.staff for each row execute function private.revoke_disabled_calendar();
create trigger disable_calendar_employee after update of active on private.employee_accounts for each row execute function private.revoke_disabled_calendar();
create trigger disable_calendar_manager after update of active on public.manager_profiles for each row execute function private.revoke_disabled_calendar();
revoke all on function private.revoke_disabled_calendar() from public,anon,authenticated;


-- Flush deferred validation before subsequent table changes, retaining atomic installation.
set constraints all immediate;
set constraints all deferred;

-- 015_employee_roles
alter table public.manager_profiles add column linked_staff_id text unique references public.staff(id);
create or replace function private.person_is_shl(p_person text) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.manager_profiles where active and (case when linked_staff_id is null then 'm:'||id::text else 's:'||linked_staff_id end)=p_person)$$;
create or replace function private.my_person() returns text language sql stable security definer set search_path='' as $$select coalesce((select case when linked_staff_id is null then 'm:'||id::text else 's:'||linked_staff_id end from public.manager_profiles where id=auth.uid() and active),'s:'||private.employee_staff())$$;
create or replace function private.person_active(p_person text) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.staff s where 's:'||s.id=p_person and s.active and not exists(select 1 from public.manager_profiles m where m.linked_staff_id=s.id and m.active and not m.on_roster)) or exists(select 1 from public.manager_profiles where 'm:'||id::text=p_person and active and on_roster and linked_staff_id is null)$$;
create function public.set_employee_role(p_id uuid,p_role text,p_version int,p_manager_version int,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a private.employee_accounts;m public.manager_profiles;s public.staff;prior private.scheduler_submissions;payload jsonb:=jsonb_build_object('id',p_id,'role',p_role,'version',p_version,'manager_version',p_manager_version);
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.is_admin() then raise exception 'IT Admin access required';end if;
 if p_submission is null or p_role is null or p_role not in ('employee','ca','manager','it') then raise exception 'Choose an account role';end if;
 select * into prior from private.scheduler_submissions where id=p_submission;
 if found then if prior.actor<>auth.uid() or prior.action<>'employee_role' or prior.payload<>payload then raise exception 'Submission changed. Reload';end if;return prior.result;end if;
 select * into a from private.employee_accounts where id=p_id for update;
 select * into m from public.manager_profiles where id=p_id for update;
 if a.id is null or not a.active or p_version is null or a.version<>p_version or coalesce(m.version,0)<>coalesce(p_manager_version,0) then raise exception 'Account changed or inactive. Reload';end if;
 select * into s from public.staff where id=a.staff_id;
 if not s.active then raise exception 'Reactivate this employee before changing their role';end if;
 if m.id is not null and m.linked_staff_id is distinct from a.staff_id then raise exception 'Existing account links require IT review';end if;
 if m.active and m.is_gm and p_role in ('employee','ca') then raise exception 'Assign a replacement GM before removing manager access';end if;
 if m.active and m.is_admin and p_role<>'it' and not exists(select 1 from public.manager_profiles where id<>p_id and active and is_admin) then raise exception 'Keep at least one active IT Admin';end if;
 update private.employee_accounts set is_ca=p_role='ca',version=version+1 where id=a.id;
 if p_role in ('manager','it') then
  insert into public.manager_profiles(id,name,is_admin,linked_staff_id,on_roster) values(a.id,s.first_name||' '||s.last_name,p_role='it',s.id,true) on conflict(id) do update set active=true,is_admin=excluded.is_admin,version=public.manager_profiles.version+1;
 elsif m.id is not null then update public.manager_profiles set active=false,is_admin=false,version=version+1 where id=m.id;end if;
 perform private.schedule_audit('employee_role',a.id::text,jsonb_build_object('account',to_jsonb(a),'manager',to_jsonb(m)),jsonb_build_object('role',p_role,'staff_id',a.staff_id));
 insert into private.scheduler_submissions(id,actor,action,payload,result) values(p_submission,auth.uid(),'employee_role',payload,'{}');
 return '{}';
end $$;
create function private.linked_person_change() returns trigger language plpgsql security definer set search_path='' as $$
declare mid uuid;m public.manager_profiles;
begin
 if tg_table_name='staff' then select * into m from public.manager_profiles where linked_staff_id=new.id;
 else select * into m from public.manager_profiles where id=new.id and linked_staff_id is not null;end if;
 if m.id is null then return new;end if;
 if old.active and not new.active and m.active then
  if m.is_gm then raise exception 'Assign a replacement GM before removing this person';end if;
  if m.is_admin and not exists(select 1 from public.manager_profiles where active and is_admin and id<>m.id) then raise exception 'Keep at least one active IT Admin';end if;
  update public.manager_profiles set active=false,is_admin=false,version=version+1 where id=m.id;
 end if;
 if tg_table_name='staff' then update public.manager_profiles set name=new.first_name||' '||new.last_name,version=version+1 where id=m.id and name is distinct from new.first_name||' '||new.last_name;end if;
 return new;
end $$;
create trigger linked_staff_change after update on public.staff for each row execute function private.linked_person_change();
create trigger linked_account_change after update of active on private.employee_accounts for each row execute function private.linked_person_change();
create or replace function public.scheduler_read(p_week date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;w private.schedule_weeks;r private.schedule_revisions;m boolean:=private.is_manager();ca boolean:=private.is_ca();v_staff_id text:=private.employee_staff();my_group text;my_person text:=private.my_person();
begin
 if not private.scheduler_member() then raise exception 'Your account needs active workspace access';end if;
 if extract(dow from p_week)<>0 then raise exception 'Choose a Sunday';end if;
 select * into w from private.schedule_weeks where week_start=p_week;
 if m then select * into r from private.schedule_revisions where id=w.draft_id;end if;
 my_group:=case when m then 'SHL' else (select department from public.staff where id=v_staff_id) end;
 result:=jsonb_build_object(
 'self',jsonb_build_object('id',auth.uid(),'person_id',my_person,'staff_id',v_staff_id,'name',private.account_name(auth.uid()),'is_manager',m,'is_ca',ca,'is_admin',private.is_admin()),
 'week',jsonb_build_object('start',p_week,'published_id',w.published_id,'draft',case when m and r.id is not null then to_jsonb(r)||jsonb_build_object('release_name',private.account_name(r.release_by)) else null end),
 'people',coalesce((select jsonb_agg(p order by p->>'name') from (
  select jsonb_build_object('id','s:'||s.id,'staff_id',s.id,'name',s.first_name||' '||s.last_name,'group',case when private.person_is_shl('s:'||s.id) then 'SHL' else s.department end,'primary_job_id',s.primary_job_id,'active',s.active,'is_trainer',s.is_trainer,'on_roster',coalesce((select on_roster from public.manager_profiles where linked_staff_id=s.id and active),true),'is_ca',exists(select 1 from private.employee_accounts a where a.staff_id=s.id and a.active and a.is_ca)) p from public.staff s where s.active or m or ca or exists(select 1 from private.published_shifts() z where z->>'person_id'='s:'||s.id)
  union all select jsonb_build_object('id','m:'||id,'name',name,'group','SHL','active',active,'on_roster',on_roster,'is_trainer',false,'version',version) from public.manager_profiles mp where linked_staff_id is null and (active or m or exists(select 1 from private.published_shifts() z where z->>'person_id'='m:'||mp.id::text))) q),'[]'),
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
   if s->>'id' is null or p is null or starts is null or ends is null or s->>'slot' not in ('1','2') or s->>'slot' is null then raise exception 'Missing shift fields';end if;
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


revoke all on function private.person_is_shl(text),private.linked_person_change() from public,anon,authenticated;
revoke all on function public.set_employee_role(uuid,text,int,int,uuid) from public,anon;
grant execute on function public.set_employee_role(uuid,text,int,int,uuid) to authenticated;


-- Flush deferred validation before subsequent table changes, retaining atomic installation.
set constraints all immediate;
set constraints all deferred;

-- 010_scheduler_cron
create extension if not exists pg_cron;
-- One stable job name: repeated installation replaces the existing job.
select cron.schedule('mission-schedule-release','* * * * *','select private.run_schedule_releases()');

commit;
