begin;
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
commit;
