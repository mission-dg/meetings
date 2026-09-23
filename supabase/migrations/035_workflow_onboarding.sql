begin;
create table private.onboarding_progress(user_id uuid not null references auth.users(id),chapter text not null,content_version int not null check(content_version>0),status text not null check(status in ('deferred','in_progress','completed')),step int not null default 0 check(step>=0),updated_at timestamptz not null default now(),primary key(user_id,chapter,content_version));
create table private.shift_presets(id uuid primary key,name text not null check(length(trim(name)) between 1 and 80),job_id uuid references public.training_positions(id),assignment_type text not null check(assignment_type in ('regular','opening_office','closing_office','training')),start_time time not null,end_time time not null,next_day boolean not null default false,active boolean not null default true,version int not null default 1,created_by uuid not null references auth.users(id));
create table private.workflow_submissions(user_id uuid not null,submission uuid not null,payload jsonb not null,result jsonb not null,primary key(user_id,submission));
alter table private.onboarding_progress enable row level security;
alter table private.shift_presets enable row level security;
alter table private.workflow_submissions enable row level security;
revoke all on private.onboarding_progress,private.shift_presets,private.workflow_submissions from public,anon,authenticated;
create function public.onboarding_read() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.scheduler_member() then raise exception 'Active account required';end if;
 return coalesce((select jsonb_agg(to_jsonb(p)-'user_id') from private.onboarding_progress p where user_id=auth.uid()),'[]');
end $$;
create function public.onboarding_save(p_chapter text,p_content_version int,p_status text,p_step int default 0) returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.scheduler_member() then raise exception 'Active account required';end if;
 if p_chapter not in ('employee','manager','it','ca','practice_employee','practice_manager','practice_it') or p_content_version<>1 or p_step not between 0 and 20 or p_status not in ('deferred','in_progress','completed') then raise exception 'Invalid walkthrough progress';end if;
 if p_chapter in ('manager','practice_manager') and not private.is_manager() or p_chapter in ('it','practice_it') and not private.is_admin() or p_chapter='ca' and not private.is_ca() then raise exception 'Walkthrough unavailable';end if;
 insert into private.onboarding_progress values(auth.uid(),p_chapter,p_content_version,p_status,p_step,now()) on conflict(user_id,chapter,content_version) do update set status=excluded.status,step=excluded.step,updated_at=excluded.updated_at;
end $$;
create function public.shift_presets_read() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_manager() then raise exception 'Scheduling manager required';end if;
 return coalesce((select jsonb_agg(to_jsonb(p) order by name) from private.shift_presets p),'[]');
end $$;
create function public.shift_preset_save(p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare p private.shift_presets;before_value jsonb;result jsonb;prior private.workflow_submissions;duration interval;
begin
 if not private.is_manager() then raise exception 'Scheduling manager required';end if;
 if p_submission is null then raise exception 'Submission required';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_submission::text,0));
 select * into prior from private.workflow_submissions where user_id=auth.uid() and submission=p_submission;
 if found then if prior.payload<>p_payload then raise exception 'Submission changed';end if;return prior.result;end if;
 if p_payload->>'id' is not null then
  select * into p from private.shift_presets where id=(p_payload->>'id')::uuid for update;
  if not found or p.version is distinct from (p_payload->>'version')::int then raise exception 'Preset changed. Refresh and review again';end if;
  before_value:=to_jsonb(p);
 else p.id:=gen_random_uuid();p.created_by:=auth.uid();p.version:=0;end if;
 if coalesce((p_payload->>'archive')::boolean,false) then
  if before_value is null then raise exception 'Choose a preset';end if;p.active:=false;
 else
  p.name:=trim(p_payload->>'name');p.job_id:=(p_payload->>'job_id')::uuid;p.assignment_type:=p_payload->>'assignment_type';p.start_time:=(p_payload->>'start_time')::time;p.end_time:=(p_payload->>'end_time')::time;p.next_day:=(p_payload->>'next_day')::boolean;p.active:=true;
  duration:=p.end_time-p.start_time+case when p.next_day then interval '1 day' else interval '0' end;
  if duration<=interval '0' or duration>interval '24 hours' then raise exception 'Preset must last more than zero and at most 24 hours';end if;
  if p.job_id is not null and not exists(select 1 from public.training_positions where id=p.job_id and active) then raise exception 'Choose an active job';end if;
  if p.assignment_type<>'regular' and p.job_id is not null then raise exception 'Only regular work has an assigned job';end if;
 end if;
 p.version:=p.version+1;
 insert into private.shift_presets select p.* on conflict(id) do update set name=excluded.name,job_id=excluded.job_id,assignment_type=excluded.assignment_type,start_time=excluded.start_time,end_time=excluded.end_time,next_day=excluded.next_day,active=excluded.active,version=excluded.version;
 result:=to_jsonb(p);perform private.schedule_audit('shift_preset',p.id::text,before_value,result);
 insert into private.workflow_submissions values(auth.uid(),p_submission,p_payload,result);return result;
end $$;
create function public.assignment_candidates(p_week date,p_revision uuid,p_version int,p_shift jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d jsonb;p jsonb;s jsonb;all_shifts jsonb;baseline jsonb;rows jsonb:='[]';reasons text[];warning text;why text;hours_value numeric;start_at timestamptz:=(p_shift->>'start')::timestamptz;end_at timestamptz:=(p_shift->>'end')::timestamptz;kind text:=coalesce(p_shift->>'assignment_type','regular');job uuid:=(p_shift->>'job_id')::uuid;
begin
 if not private.is_manager() then raise exception 'Scheduling manager required';end if;
 if start_at is null or end_at is null or end_at<=start_at or end_at-start_at>interval '24 hours' or private.planning_week(start_at)<>p_week then raise exception 'Choose valid shift dates in this week';end if;
 if kind not in ('regular','opening_office','closing_office','training') then raise exception 'Invalid assignment';end if;
 if p_revision is not null and not exists(select 1 from private.schedule_revisions r join private.schedule_weeks w on w.draft_id=r.id where r.id=p_revision and r.version=p_version and w.week_start=p_week and r.state<>'Queued') then raise exception 'Draft changed. Refresh before selecting a person';end if;
 d:=public.scheduler_read(p_week);all_shifts:=private.planning_shifts(p_revision);
 select coalesce(jsonb_agg(value),'[]') into baseline from jsonb_array_elements(all_shifts) where value->>'id' is distinct from p_shift->>'id';
 for p in select value from jsonb_array_elements(d->'people') loop
  reasons:='{}';warning:=null;
  if not coalesce((p->>'active')::boolean,false) or not coalesce((p->>'on_roster')::boolean,false) then reasons:=array_append(reasons,'Not active on roster');end if;
  if kind in ('opening_office','closing_office') or kind='regular' and job is null then
   if not private.person_is_shl(p->>'id') or kind<>'regular' and private.person_employment(p->>'id')='Unclassified' then reasons:=array_append(reasons,'Requires an eligible SHL');end if;
  elsif kind='regular' then
   if not exists(select 1 from public.training_positions where id=job and active) then reasons:=array_append(reasons,'Choose an active job');
   elsif not private.job_qualified(p->>'staff_id',job) then warning:='Qualification not signed off — review coaching and assignment requirements';end if;
  end if;
  why:=private.person_conflict(p->>'id',start_at,end_at);if why is not null then reasons:=array_append(reasons,why);end if;
  if exists(select 1 from jsonb_array_elements(baseline) x where x->>'person_id'=p->>'id' and (x->>'start')::timestamptz<end_at and (x->>'end')::timestamptz>start_at) then reasons:=array_append(reasons,'Overlapping assignment');end if;
  select coalesce(sum(extract(epoch from least((x->>'end')::timestamptz,(p_week+7)::timestamp at time zone 'America/Chicago')-greatest((x->>'start')::timestamptz,p_week::timestamp at time zone 'America/Chicago')))/3600,0) into hours_value from jsonb_array_elements(baseline) x where x->>'person_id'=p->>'id' and (x->>'start')::timestamptz<(p_week+7)::timestamp at time zone 'America/Chicago' and (x->>'end')::timestamptz>p_week::timestamp at time zone 'America/Chicago';
  hours_value:=hours_value+extract(epoch from least(end_at,(p_week+7)::timestamp at time zone 'America/Chicago')-start_at)/3600;
  rows:=rows||jsonb_build_array(jsonb_build_object('id',p->>'id','reasons',to_jsonb(reasons),'warning',warning,'hours',case when private.person_employment(p->>'id')='Salaried' then null else round(hours_value,4) end));
 end loop;return jsonb_build_object('candidates',rows,'revision',p_revision,'version',p_version);
end $$;
revoke all on function public.onboarding_read(),public.onboarding_save(text,int,text,int),public.shift_presets_read(),public.shift_preset_save(jsonb,uuid),public.assignment_candidates(date,uuid,int,jsonb) from public,anon;
grant execute on function public.onboarding_read(),public.onboarding_save(text,int,text,int),public.shift_presets_read(),public.shift_preset_save(jsonb,uuid),public.assignment_candidates(date,uuid,int,jsonb) to authenticated;
commit;
