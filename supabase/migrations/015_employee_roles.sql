begin;
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
commit;
