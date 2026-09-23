begin;
-- Leadership qualifications are derived, never inserted as completed training.
insert into public.training_positions(name,department,created_by)
select 'GM','SHL',(select id from public.manager_profiles where is_admin order by id limit 1)
where not exists(select 1 from public.training_positions where name='GM' and department='SHL');
alter table public.staff add column leadership_title text check(leadership_title in ('GM','sSHL'));
alter table public.staff add column previous_primary_job_id uuid references public.training_positions(id);

create function private.person_leadership(p_person text) returns text language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from public.manager_profiles m where m.active and m.is_gm and
 (case when m.linked_staff_id is null then 'm:'||m.id::text else 's:'||m.linked_staff_id end)=p_person) then 'GM'
 when exists(select 1 from public.staff s where 's:'||s.id=p_person and private.staff_shl_code(s.id)='sSHL') then 'sSHL' end
$$;
create function private.inherited_job_source(p_person text,p_job uuid) returns text language sql stable security definer set search_path='' as $$
 select private.person_leadership(p_person) from public.training_positions j where j.id=p_job and j.active
 and (j.department in ('FOH','BOH','Catering') or j.name='GM' and j.department='SHL' and private.person_leadership(p_person)='GM')
$$;
create or replace function private.job_qualified(p_staff text,p_job uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.training_signoffs where staff_id=p_staff and training_position_id=p_job and active)
 or private.inherited_job_source('s:'||p_staff,p_job) is not null
$$;
create function private.person_job_qualified(p_person text,p_job uuid) returns boolean language sql stable security definer set search_path='' as $$
 select private.inherited_job_source(p_person,p_job) is not null or
 exists(select 1 from public.staff s where 's:'||s.id=p_person and private.job_qualified(s.id,p_job))
$$;
-- The trigger also covers imports and direct writes; titles cannot be forged by choosing a job.
create function private.leadership_primary_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare title text:=private.person_leadership('s:'||new.id); job uuid; prior uuid;
begin
 if TG_OP='INSERT' then new.previous_primary_job_id:=null;new.leadership_title:=null;
 else new.previous_primary_job_id:=old.previous_primary_job_id;new.leadership_title:=old.leadership_title;end if;
 if title is not null then
  select id into job from public.training_positions where department='SHL' and name=title and active;
  if TG_OP='UPDATE' and old.leadership_title is not null and new.primary_job_id is distinct from old.primary_job_id and new.primary_job_id is distinct from job then
   raise exception 'Leadership primary job is managed by the GM designation or sSHL qualification';
  end if;
  if new.leadership_title is null then
   new.previous_primary_job_id:=case when exists(select 1 from public.training_positions where id=new.primary_job_id and department in ('FOH','BOH','Catering')) then new.primary_job_id end;
  end if;
  new.primary_job_id:=job;new.department:='SHL';new.leadership_title:=title;
 elsif new.leadership_title is not null then
  prior:=new.previous_primary_job_id;
  new.primary_job_id:=null;new.leadership_title:=null;new.previous_primary_job_id:=null;
  if exists(select 1 from public.training_positions where id=prior and active) and private.job_qualified(new.id,prior) then
   new.primary_job_id:=prior;select department into new.department from public.training_positions where id=prior;
  end if;
 elsif exists(select 1 from public.training_positions where id=new.primary_job_id and name='GM' and department='SHL') then
  raise exception 'GM primary job requires an active GM designation';
 end if;
 return new;
end $$;
create trigger aa_leadership_primary before insert or update on public.staff for each row execute function private.leadership_primary_guard();
create function private.refresh_leadership_primary(p_staff text) returns void language plpgsql security definer set search_path='' as $$
begin
 update public.staff set primary_job_id=primary_job_id where id=p_staff and leadership_title is distinct from private.person_leadership('s:'||id);
end $$;
create function private.leadership_changed() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='training_signoffs' then
  if TG_OP<>'INSERT' then perform private.refresh_leadership_primary(old.staff_id);end if;
  if TG_OP<>'DELETE' then perform private.refresh_leadership_primary(new.staff_id);end if;
 else
  if TG_OP<>'INSERT' then perform private.refresh_leadership_primary(old.linked_staff_id);end if;
  if TG_OP<>'DELETE' then perform private.refresh_leadership_primary(new.linked_staff_id);end if;
 end if;
 return null;
end $$;
create trigger zz_leadership_primary after insert or update or delete on public.training_signoffs for each row execute function private.leadership_changed();
create trigger zz_leadership_primary after insert or update or delete on public.manager_profiles for each row execute function private.leadership_changed();
-- GM is an account appointment, never an earned/imported qualification.
create function private.gm_job_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='training_signoffs' then
  if exists(select 1 from public.training_positions where id=new.training_position_id and name='GM' and department='SHL') then raise exception 'GM qualification comes from the active GM designation';end if;
 elsif TG_OP='DELETE' then
  if old.name='GM' and old.department='SHL' then raise exception 'GM is a reserved leadership title';end if;return old;
 elsif (old.name='GM' and old.department='SHL') or (new.name='GM' and new.department='SHL') then
  if new.name is distinct from old.name or new.department is distinct from old.department or new.active is distinct from old.active then raise exception 'GM is a reserved leadership title';end if;
 end if;return new;
end $$;
create trigger gm_job_guard before update or delete on public.training_positions for each row execute function private.gm_job_guard();
create trigger gm_qualification_guard before insert or update on public.training_signoffs for each row execute function private.gm_job_guard();

create function private.effective_qualifications() returns setof jsonb language sql stable security definer set search_path='' as $$
 select to_jsonb(f) from public.training_signoffs f
 union all
 select jsonb_build_object('id','inherited:'||s.id||':'||j.id,'staff_id',s.id,'training_position_id',j.id,'active',true,
 'origin','leadership','inherited_source',private.inherited_job_source('s:'||s.id,j.id),'version',0)
 from public.staff s cross join public.training_positions j
 where private.inherited_job_source('s:'||s.id,j.id) is not null
 and not exists(select 1 from public.training_signoffs f where f.staff_id=s.id and f.training_position_id=j.id and f.active)
$$;
create function public.qualifications_read() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.scheduler_member() then raise exception 'Active account required';end if;
 return coalesce((select jsonb_agg(f) from private.effective_qualifications() f
 where private.is_manager() or private.is_ca() or f->>'staff_id'=private.employee_staff()),'[]');
end $$;
alter function public.scheduler_read(date) rename to scheduler_read_before_leadership;
revoke all on function public.scheduler_read_before_leadership(date) from public,anon,authenticated;
create function public.scheduler_read(p_week date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 r:=public.scheduler_read_before_leadership(p_week);
 r:=jsonb_set(r,'{signoffs}',public.qualifications_read());
 r:=jsonb_set(r,'{people}',coalesce((select jsonb_agg(p||jsonb_build_object(
 'leadership_title',private.person_leadership(p->>'id'),
 'inherited_job_ids',coalesce((select jsonb_agg(j.id) from public.training_positions j where private.inherited_job_source(p->>'id',j.id) is not null),'[]')))
 from jsonb_array_elements(r->'people') p),'[]'));
 return r;
end $$;
-- Reconcile existing leaders, retaining their previous primary job and every training record.
update public.staff set primary_job_id=primary_job_id where private.person_leadership('s:'||id) is not null;
revoke all on function private.person_leadership(text),private.inherited_job_source(text,uuid),private.person_job_qualified(text,uuid),private.leadership_primary_guard(),private.refresh_leadership_primary(text),private.leadership_changed(),private.gm_job_guard(),private.effective_qualifications() from public,anon,authenticated;
revoke all on function public.qualifications_read(),public.scheduler_read(date) from public,anon;
grant execute on function public.qualifications_read(),public.scheduler_read(date) to authenticated;
create or replace function public.assignment_candidates(p_week date,p_revision uuid,p_version int,p_shift jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
   elsif not private.person_job_qualified(p->>'id',job) then warning:='Qualification not signed off — review coaching and assignment requirements';end if;
  end if;
  why:=private.person_conflict(p->>'id',start_at,end_at);if why is not null then reasons:=array_append(reasons,why);end if;
  if exists(select 1 from jsonb_array_elements(baseline) x where x->>'person_id'=p->>'id' and (x->>'start')::timestamptz<end_at and (x->>'end')::timestamptz>start_at) then reasons:=array_append(reasons,'Overlapping assignment');end if;
  select coalesce(sum(extract(epoch from least((x->>'end')::timestamptz,(p_week+7)::timestamp at time zone 'America/Chicago')-greatest((x->>'start')::timestamptz,p_week::timestamp at time zone 'America/Chicago')))/3600,0) into hours_value from jsonb_array_elements(baseline) x where x->>'person_id'=p->>'id' and (x->>'start')::timestamptz<(p_week+7)::timestamp at time zone 'America/Chicago' and (x->>'end')::timestamptz>p_week::timestamp at time zone 'America/Chicago';
  hours_value:=hours_value+extract(epoch from least(end_at,(p_week+7)::timestamp at time zone 'America/Chicago')-start_at)/3600;
  rows:=rows||jsonb_build_array(jsonb_build_object('id',p->>'id','reasons',to_jsonb(reasons),'warning',warning,'hours',case when private.person_employment(p->>'id')='Salaried' then null else round(hours_value,4) end));
 end loop;return jsonb_build_object('candidates',rows,'revision',p_revision,'version',p_version);
end $$;
create or replace function private.trade_assignment_error_before_staff_meetings(s jsonb,p_person text,p_other uuid default null) returns text language plpgsql stable security definer set search_path='' as $$
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
  if not exists(select 1 from public.training_positions where id=(s->>'job_id')::uuid and active) or not private.person_job_qualified(p_person,(s->>'job_id')::uuid) then return 'Job qualification required';end if;
 end if;
 why:=private.person_conflict(p_person,(s->>'start')::timestamptz,(s->>'end')::timestamptz);if why is not null then return 'Availability or time-off conflict';end if;
 if exists(select 1 from private.published_shifts() x where x->>'person_id'=p_person and x->>'id'<>s->>'id' and (p_other is null or x->>'id'<>p_other::text) and (x->>'start')::timestamptz<(s->>'end')::timestamptz and (x->>'end')::timestamptz>(s->>'start')::timestamptz) then return 'Overlapping shift';end if;
 return null;
end $$;
create or replace function public.operations_read(p_module text,p_view text,p_offset int default 0,p_search text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare manager boolean:=p_view<>'employee' and private.is_manager();items jsonb;total bigint;person text:=private.my_person();g text;own_contact jsonb;
begin
 if not private.scheduler_member() then raise exception 'Active workspace access required';end if;
 if p_view not in ('employee','manager','it') or p_view is null or p_view='manager' and not private.is_manager() or p_view='it' and not private.is_admin() then raise exception 'Workspace access required';end if;
 if p_offset<0 or p_offset is null then raise exception 'Invalid page';end if;
 if p_module in ('logbook','labor','reports','brief') and not manager then raise exception 'Manager workspace required';end if;
 if p_module='directory' then
  select count(*) into total from (select 's:'||id id,first_name||' '||last_name name from public.staff where active union all select 'm:'||id::text,name from public.manager_profiles where active and on_roster and linked_staff_id is null) x where x.name ilike '%'||p_search||'%';
  select coalesce(jsonb_agg(v),'[]') into items from (select jsonb_build_object('person_id',x.id,'name',x.name,'group',x.g,'job',x.job,'trainer',x.trainer,'version',case when x.id=person then coalesce(c.version,0) end,'phone',case when manager or x.id=person or c.share_phone then c.phone end,'email',case when manager or x.id=person or c.share_email then c.email end,'share_phone',case when x.id=person then coalesce(c.share_phone,false) end,'share_email',case when x.id=person then coalesce(c.share_email,false) end,'emergency_name',case when manager or x.id=person then c.emergency_name end,'emergency_phone',case when manager or x.id=person then c.emergency_phone end,'birthday_month',c.birthday_month,'birthday_day',c.birthday_day) v from (select 's:'||s.id id,s.first_name||' '||s.last_name name,coalesce(private.staff_shl_code(s.id),case when private.person_is_shl('s:'||s.id) and private.person_employment('s:'||s.id)='Salaried' then 'sSHL' when private.person_is_shl('s:'||s.id) and private.person_employment('s:'||s.id)='Hourly' then 'hSHL' else s.department end) g,case when private.person_leadership('s:'||s.id)='GM' then 'GM' when private.staff_shl_code(s.id)='sSHL' or private.person_is_shl('s:'||s.id) and private.person_employment('s:'||s.id)='Salaried' then 'sSHL' else j.name end job,s.is_trainer trainer from public.staff s left join public.training_positions j on j.id=s.primary_job_id where s.active union all select 'm:'||id::text,name,case employment_type when 'Hourly' then 'hSHL' when 'Salaried' then 'sSHL' else 'SHL' end,case when is_gm then 'GM' when employment_type='Salaried' then 'sSHL' else null end,false from public.manager_profiles where active and on_roster and linked_staff_id is null) x left join private.person_contacts c on c.person_id=x.id where x.name ilike '%'||p_search||'%' order by x.name,x.id limit 50 offset p_offset) z;
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
create or replace function public.directory_csv_review(p_rows jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
    if s.leadership_title is not null then raise exception 'Leadership primary job is managed by the GM designation or sSHL qualification';end if;
    primary_id:=(private.directory_jobs(jsonb_build_array(row->>'primary_job')))[1];
    if not primary_id=any(old_earned||earned) then raise exception 'Primary job must already be qualified or included in Earned jobs';end if;
   end if;
   if (select count(distinct j.name) from public.training_positions j where j.id=any(old_earned||earned) and j.department='SHL' and j.name in ('hSHL','sSHL'))>1 then raise exception 'Choose one SHL code. Revoke the previous SHL qualification first';end if;
   after_value:=jsonb_build_object('staff_id',s.id,'first_name',trim(row->>'first_name'),'last_name',trim(row->>'last_name'),'primary_job_id',primary_id,'primary_job',(select name from public.training_positions where id=primary_id),'earned_job_ids',to_jsonb(earned),'trainer_job_ids',to_jsonb(roles),'is_trainer',case when cardinality(roles)=0 and cardinality(s.trainer_job_ids)=0 then s.is_trainer else cardinality(roles)>0 end,'trainer_roles',row->'trainer_roles','qualifications_to_add',coalesce((select jsonb_agg(p.name order by p.name) from public.training_positions p where p.id=any(earned) and not p.id=any(old_earned)),'[]'));
   items:=items||jsonb_build_array(jsonb_build_object('row',num,'before',before_value,'after',after_value,'changed',s.first_name<>trim(row->>'first_name') or s.last_name<>trim(row->>'last_name') or s.primary_job_id is distinct from primary_id or not(s.trainer_job_ids @> roles and s.trainer_job_ids <@ roles) or s.is_trainer is distinct from (case when cardinality(roles)=0 and cardinality(s.trainer_job_ids)=0 then s.is_trainer else cardinality(roles)>0 end) or not old_earned @> earned));
  exception when others then raise exception 'Row %: %',num+1,sqlerrm;end;
 end loop;
 return jsonb_build_object('rows',items,'fingerprint',md5(items::text));
end $$;
create or replace function public.preview_employee_import(p_rows jsonb,p_effective date) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
    if s.leadership_title is not null and pid is not null and pid is distinct from s.primary_job_id then raise exception 'Leadership primary job is managed by the GM designation or sSHL qualification';end if;
    if exists(select 1 from public.training_positions where id=pid and name='GM' and department='SHL') and private.person_leadership('s:'||s.id) is distinct from 'GM' then raise exception 'GM primary job requires an active GM designation';end if;
    dep:=nullif(r->>'department','');
    if pid is not null then
     if dep is not null and dep<>(select department from public.training_positions where id=pid) then raise exception 'Position group conflicts with Primary Role';end if;
     dep:=(select department from public.training_positions where id=pid);earned:=array_append(earned,pid);
    elsif action='Add' then raise exception 'New employees require a Primary Role';end if;
    if dep is not null and dep not in ('FOH','BOH','Catering','SHL') then raise exception 'Choose FOH, HOH, Catering or SHL';end if;
    for role_name in select trim(value) from jsonb_array_elements_text(coalesce(r->'other_roles','[]')) loop
     jid:=private.import_job(role_name);if jid is not null and not jid=any(earned) then earned:=array_append(earned,jid);end if;
    end loop;
    if (select count(distinct j.name) from public.training_positions j where (j.id=any(earned) or exists(select 1 from public.training_signoffs f where f.staff_id=target and f.active and f.training_position_id=j.id)) and j.department='SHL' and j.name in ('hSHL','sSHL'))>1 then raise exception 'Choose one SHL code. Revoke the previous SHL qualification first';end if;
    if nullif(trim(r->>'hourly_wage'),'') is not null then
     if exists(select 1 from public.training_positions where id=any(earned) and department='SHL' and name='sSHL') then raise exception 'Hourly wages cannot be imported for a salaried SHL';end if;
     if trim(r->>'hourly_wage') !~ '^[0-9]+([.][0-9]{1,2})?$' then raise exception 'Hourly Wage needs a nonnegative amount with at most two decimal places';end if;
     wage:=(r->>'hourly_wage')::numeric;if wage>=100000 then raise exception 'Hourly Wage must be below 100000';end if;
     if target is not null and private.person_employment('s:'||target)='Salaried' then raise exception 'Hourly wages cannot be imported for a salaried SHL';end if;
     select * into old_rate from private.pay_rates where person_id='s:'||target and effective=p_effective;
    end if;
    row_value:=jsonb_build_object('primary_id',pid,'department',dep,'earned_ids',earned,'wage',wage,'before',jsonb_build_object('primary_role',(select name from public.training_positions where id=s.primary_job_id),'qualifications',(select coalesce(jsonb_agg(j.name order by j.name),'[]') from public.training_signoffs f join public.training_positions j on j.id=f.training_position_id where f.staff_id=target and f.active),'wage_on_date',old_rate.hourly_rate,'current_wage',(select hourly_rate from private.pay_rates where person_id='s:'||target and effective<=p_effective order by effective desc limit 1)),'after',jsonb_build_object('primary_role',coalesce((select name from public.training_positions where id=pid),(select name from public.training_positions where id=s.primary_job_id)),'qualifications_to_add',(select coalesce(jsonb_agg(j.name order by j.name),'[]') from public.training_positions j where j.id=any(earned) and not exists(select 1 from public.training_signoffs recorded where recorded.staff_id=target and recorded.training_position_id=j.id and recorded.active) and not (j.name='GM' and j.department='SHL')),'hourly_wage',wage,'effective',p_effective));
   end if;
  exception when others then row_errors:=array_append(row_errors,sqlerrm);
  end;
  foreach choices in array row_errors loop errors:=array_append(errors,'Row '||(n+1)||': '||choices);end loop;
  outrows:=outrows||jsonb_build_array(row_value||jsonb_build_object('row',n,'action',action,'target_id',target,'suggested_ids',ids,'name',case when s.id is not null then s.first_name||' '||s.last_name else concat_ws(' ',r->>'first_name',r->>'last_name') end,'errors',row_errors));
 end loop;
 return jsonb_build_object('rows',outrows,'errors',errors,'fingerprint',md5(private.import_state()||p_rows::text||p_effective::text));
end $$;
create or replace function public.admin_import_staff(p_batch uuid,p_rows jsonb,p_effective date,p_fingerprint text) returns jsonb language plpgsql security definer set search_path='' as $$
<<import_batch>>
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
   if not exists(select 1 from public.training_signoffs earned_row where earned_row.staff_id=import_batch.staff_id and earned_row.training_position_id=j and earned_row.active) and not exists(select 1 from public.training_positions where id=j and name='GM' and department='SHL') then
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

create or replace function private.refresh_leadership_primary(p_staff text) returns void language plpgsql security definer set search_path='' as $$
declare before_value jsonb; after_value jsonb; weeks text;
begin
 select to_jsonb(s) into before_value from public.staff s where id=p_staff;
 if before_value->>'leadership_title' is not distinct from private.person_leadership('s:'||p_staff) then return;end if;
 update public.staff set primary_job_id=primary_job_id where id=p_staff returning to_jsonb(staff) into after_value;
 perform private.schedule_audit('leadership_primary',p_staff,before_value,after_value);
 if before_value->>'leadership_title' is not null and after_value->>'leadership_title' is null then
  select string_agg(distinct w.week_start::text,', ' order by w.week_start::text) into weeks
  from private.schedule_weeks w join private.schedule_revisions r on r.id in (w.draft_id,w.published_id)
  cross join lateral jsonb_array_elements(r.shifts) s
  where s->>'person_id'='s:'||p_staff and (s->>'end')::timestamptz>now()
  and coalesce(s->>'assignment_type','regular')='regular' and s->>'job_id' is not null
  and not private.job_qualified(p_staff,(s->>'job_id')::uuid);
  if weeks is not null then
   perform private.notify_managers('leadership-review:'||p_staff||':'||(after_value->>'version'),
    private.person_name('s:'||p_staff)||' no longer has inherited leadership qualifications. Review future assignments in schedule weeks: '||weeks||'. Individually earned qualifications remain.');
  end if;
 end if;
end $$;
notify pgrst, 'reload schema';
commit;
