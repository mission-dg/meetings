begin;
create table private.navigation_favorites(user_id uuid primary key references auth.users(id),version int not null default 1,pages text[] not null default '{}');
alter table private.navigation_favorites enable row level security;
revoke all on private.navigation_favorites from public,anon,authenticated;
create function public.favorites_read() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_manager() then raise exception 'Manager access required';end if;
 return coalesce((select jsonb_build_object('version',version,'pages',pages) from private.navigation_favorites where user_id=auth.uid()),'{"version":0,"pages":[]}');
end $$;
create function public.favorites_save(p_version int,p_pages text[],p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.workflow_submissions;payload jsonb;result jsonb;v int;
begin
 if not private.is_manager() then raise exception 'Manager access required';end if;
 if p_submission is null then raise exception 'Submission required';end if;
 perform pg_advisory_xact_lock(hashtextextended('favorites:'||auth.uid()::text,0));
 payload:=jsonb_build_object('action','favorites','version',p_version,'pages',p_pages);
 select * into prior from private.workflow_submissions where user_id=auth.uid() and submission=p_submission;
 if found then if prior.payload is distinct from payload then raise exception 'Submission changed';end if;return prior.result;end if;
 if p_pages is null or cardinality(p_pages)>17 or exists(select 1 from unnest(p_pages) p where p is null or p not in ('home','schedule','requests','directory','training','staffMeetings','oneOnOnes','announcements','logbook','documents','reports','labor','accounts','audit','settings','help') or p='audit' and not private.is_admin()) or cardinality(p_pages)<>(select count(distinct p) from unnest(p_pages) p) then raise exception 'Choose authorized pages once each';end if;
 select version into v from private.navigation_favorites where user_id=auth.uid();
 if p_version is distinct from coalesce(v,0) then raise exception 'Favorites changed on another device. Reload';end if;
 insert into private.navigation_favorites values(auth.uid(),1,p_pages) on conflict(user_id) do update set version=navigation_favorites.version+1,pages=excluded.pages;
 result:=public.favorites_read();insert into private.workflow_submissions values(auth.uid(),p_submission,payload,result);return result;
end $$;
create function public.copy_week_read(p_week date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r private.schedule_revisions;items jsonb;
begin
 if not private.is_manager() then raise exception 'Manager access required';end if;
 if p_week is null or extract(dow from p_week)<>0 then raise exception 'Choose a Sunday';end if;
 select rr.* into r from private.schedule_weeks w join private.schedule_revisions rr on rr.id=w.published_id where w.week_start=p_week;
 select coalesce(jsonb_agg(s),'[]') into items from jsonb_array_elements(coalesce(r.shifts,'[]')) s where coalesce(s->>'assignment_type','regular')<>'training' and not exists(select 1 from private.staff_meetings m cross join lateral jsonb_array_elements(m.generated) g where g->>'id'=s->>'id');
 return jsonb_build_object('revision',r.id,'shifts',items);
end $$;
create function public.copy_week_save(p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.workflow_submissions;payload jsonb;source jsonb;items jsonb;draft jsonb;result jsonb;s jsonb;lo timestamp;hi timestamp;delta int;target date:=(p_payload->>'week')::date;origin date:=(p_payload->>'source_week')::date;r private.schedule_revisions;
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.is_manager() then raise exception 'Manager access required';end if;
 if p_submission is null then raise exception 'Submission required';end if;
 payload:=jsonb_build_object('action','copy_week','value',p_payload);
 select * into prior from private.workflow_submissions where user_id=auth.uid() and submission=p_submission;
 if found then if prior.payload is distinct from payload then raise exception 'Submission changed';end if;return prior.result;end if;
 if target is null or origin is null or target<=origin or extract(dow from target)<>0 then raise exception 'Choose an earlier source week and a Sunday destination';end if;
 source:=public.copy_week_read(origin);
 if source->>'revision' is null or source->>'revision' is distinct from p_payload->>'source_revision' then raise exception 'Source publication changed. Reload the source week';end if;
 if jsonb_typeof(p_payload->'ids') is distinct from 'array' or jsonb_array_length(p_payload->'ids')=0 then raise exception 'Select work shifts';end if;
 if exists(select 1 from jsonb_array_elements_text(p_payload->'ids') x where not exists(select 1 from jsonb_array_elements(source->'shifts') candidate where candidate->>'id'=x)) then raise exception 'Selected shift unavailable';end if;
 delta:=target-origin;items:='[]';
 for s in select value from jsonb_array_elements(source->'shifts') where p_payload->'ids' ? (value->>'id') loop
  lo:=(s->>'start')::timestamptz at time zone 'America/Chicago'+make_interval(days=>delta);hi:=(s->>'end')::timestamptz at time zone 'America/Chicago'+make_interval(days=>delta);
  if ((lo at time zone 'America/Chicago') at time zone 'America/Chicago')<>lo or ((hi at time zone 'America/Chicago') at time zone 'America/Chicago')<>hi or (((lo at time zone 'America/Chicago')-interval '1 hour') at time zone 'America/Chicago')=lo or (((hi at time zone 'America/Chicago')-interval '1 hour') at time zone 'America/Chicago')=hi then raise exception 'Copied time crosses a daylight-saving gap or repeated hour. Add that shift manually';end if;
  items:=items||jsonb_build_array(s||jsonb_build_object('id',gen_random_uuid(),'start',lo at time zone 'America/Chicago','end',hi at time zone 'America/Chicago','qualification_reason',''));
 end loop;
 draft:=public.scheduler_action('draft',jsonb_build_object('week',target),gen_random_uuid());select * into r from private.schedule_revisions where id=(draft->>'id')::uuid;
 result:=public.scheduler_action('save',jsonb_build_object('id',r.id,'version',r.version,'shifts',items),gen_random_uuid());
 result:=result||jsonb_build_object('id',r.id);insert into private.workflow_submissions values(auth.uid(),p_submission,payload,result);return result;
end $$;
alter table private.staff_meetings add column attendance_version int not null default 0;
create table private.staff_meeting_attendance(meeting_id uuid not null references private.staff_meetings(id),person_id text not null,status text not null check(status in ('Not recorded','Attended','Absent','Canceled')),recorded_by uuid not null references auth.users(id),recorded_at timestamptz not null default now(),primary key(meeting_id,person_id));
alter table private.staff_meeting_attendance enable row level security;
revoke all on private.staff_meeting_attendance from public,anon,authenticated;
alter function public.staff_meetings_read(boolean) rename to staff_meetings_read_before_attendance;
revoke all on function public.staff_meetings_read_before_attendance(boolean) from public,anon,authenticated;
create function public.staff_meetings_read(p_employee boolean default false) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 r:=public.staff_meetings_read_before_attendance(p_employee);
 if p_employee or not private.is_manager() then return r;end if;
 return jsonb_build_object('meetings',(select coalesce(jsonb_agg(item||jsonb_build_object('attendance_version',m.attendance_version,'attendance',(select coalesce(jsonb_object_agg(person_id,status),'{}') from private.staff_meeting_attendance where meeting_id=m.id)) order by m.starts_at),'[]') from jsonb_array_elements(r->'meetings') item join private.staff_meetings m on m.id=(item->>'id')::uuid));
end $$;
create function public.staff_meeting_attendance_save(p_payload jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m private.staff_meetings;prior private.workflow_submissions;payload jsonb;result jsonb;entry record;before_value jsonb;
begin
 perform pg_advisory_xact_lock(61902028);
 if not private.is_manager() then raise exception 'Manager access required';end if;
 if p_submission is null then raise exception 'Submission required';end if;
 payload:=jsonb_build_object('action','attendance','value',p_payload);
 select * into prior from private.workflow_submissions where user_id=auth.uid() and submission=p_submission;
 if found then if prior.payload is distinct from payload then raise exception 'Submission changed';end if;return prior.result;end if;
 select * into m from private.staff_meetings where id=(p_payload->>'id')::uuid for update;
 if m.id is null or m.created_by<>auth.uid() then raise exception 'Only the meeting creator can record attendance';end if;
 if m.cancelled or m.ends_at>now() then raise exception 'Record attendance after the meeting ends';end if;
 if not exists(select 1 from private.published_shifts() s join lateral jsonb_array_elements(m.generated) g on g->>'id'=s->>'id' where g->>'assignment_type'='training') then raise exception 'Meeting must be published before recording attendance';end if;
 if m.attendance_version is distinct from (p_payload->>'version')::int then raise exception 'Attendance changed. Reload before saving';end if;
 if jsonb_typeof(p_payload->'attendance') is distinct from 'object' then raise exception 'Choose attendance statuses';end if;
 if exists(select 1 from jsonb_each_text(p_payload->'attendance') e where not(e.key=any(m.people)) or e.value is null or e.value not in ('Not recorded','Attended','Absent','Canceled')) then raise exception 'Invalid attendee or status';end if;
 select coalesce(jsonb_object_agg(person_id,status),'{}') into before_value from private.staff_meeting_attendance where meeting_id=m.id;
 for entry in select * from jsonb_each_text(p_payload->'attendance') loop
  insert into private.staff_meeting_attendance values(m.id,entry.key,entry.value,auth.uid(),now()) on conflict(meeting_id,person_id) do update set status=excluded.status,recorded_by=excluded.recorded_by,recorded_at=excluded.recorded_at;
 end loop;
 update private.staff_meetings set attendance_version=attendance_version+1 where id=m.id;
 result:=jsonb_build_object('version',m.attendance_version+1);
 perform private.schedule_audit('staff_meeting_attendance',m.id::text,before_value,p_payload->'attendance');
 insert into private.workflow_submissions values(auth.uid(),p_submission,payload,result);return result;
end $$;

create or replace function public.onboarding_save(p_chapter text,p_content_version int,p_status text,p_step int default 0) returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.scheduler_member() then raise exception 'Active account required';end if;
 if p_chapter not in ('employee','manager','it','ca','practice_employee','practice_manager','practice_it','build_week','approve_requests','staff_meeting_tasks','training_tasks') or p_content_version<>1 or p_step not between 0 and 20 or p_status not in ('deferred','in_progress','completed') then raise exception 'Invalid walkthrough progress';end if;
 if p_chapter in ('manager','practice_manager','build_week','approve_requests','staff_meeting_tasks','training_tasks') and not private.is_manager() or p_chapter in ('it','practice_it') and not private.is_admin() or p_chapter='ca' and not private.is_ca() then raise exception 'Walkthrough unavailable';end if;
 insert into private.onboarding_progress values(auth.uid(),p_chapter,p_content_version,p_status,p_step,now()) on conflict(user_id,chapter,content_version) do update set status=excluded.status,step=excluded.step,updated_at=excluded.updated_at;
end $$;

revoke all on function public.favorites_read(),public.favorites_save(int,text[],uuid),public.copy_week_read(date),public.copy_week_save(jsonb,uuid),public.staff_meetings_read(boolean),public.staff_meeting_attendance_save(jsonb,uuid) from public,anon;
grant execute on function public.favorites_read(),public.favorites_save(int,text[],uuid),public.copy_week_read(date),public.copy_week_save(jsonb,uuid),public.staff_meetings_read(boolean),public.staff_meeting_attendance_save(jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
