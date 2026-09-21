-- Apply once to a new Supabase project. No employee data is embedded here.
begin;
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create table public.manager_profiles (
 id uuid primary key references auth.users(id), name text not null check(length(trim(name))>0),
 active boolean not null default true, is_gm boolean not null default false, is_admin boolean not null default false
);
create unique index one_active_gm on public.manager_profiles ((true)) where active and is_gm;
create function private.require_gm() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.manager_profiles) and (select count(*) from public.manager_profiles where active and is_gm)<>1 then raise exception 'Exactly one active manager must be GM';end if;
 return null;
end $$;
create constraint trigger require_active_gm after insert or update or delete on public.manager_profiles deferrable initially deferred for each row execute function private.require_gm();
create function private.is_manager() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.manager_profiles where id=auth.uid() and active)
$$;
create function private.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.manager_profiles where id=auth.uid() and active and is_admin)
$$;
create function private.is_gm() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.manager_profiles where id=auth.uid() and active and is_gm)
$$;
revoke all on function private.is_manager(),private.is_admin(),private.is_gm() from public;
grant execute on function private.is_manager(),private.is_admin(),private.is_gm() to authenticated;

create table public.staff (
 id text primary key, first_name text not null check(length(trim(first_name))>0), last_name text not null check(length(trim(last_name))>0),
 department text not null check(department in ('FOH','BOH')), active boolean not null default true,
 priority boolean not null default false, priority_set_at timestamptz,
 created_by uuid not null default auth.uid() references public.manager_profiles(id), created_at timestamptz not null default now()
);
create unique index staff_ids_ignore_case on public.staff(lower(id));
create function private.staff_id() returns trigger language plpgsql set search_path='' as $$
declare f text; l text; candidate text; n int;
begin
 if TG_OP='UPDATE' then
  if new.id<>old.id or new.created_by<>old.created_by then raise exception 'Employee identity cannot change'; end if;
  if new.priority and not old.priority then new.priority_set_at:=now(); elsif not new.priority then new.priority_set_at:=null;end if;
  return new;
 end if;
 if new.priority then new.priority_set_at:=now();end if;
 perform pg_advisory_xact_lock(61902026);
 f:=regexp_replace(trim(new.first_name),'\s','','g');l:=regexp_replace(trim(new.last_name),'[\s.''’\-]','','g');
 if length(f)=0 or length(l)=0 then raise exception 'First and last names are required'; end if;
 for n in 1..least(3,length(l)) loop
  candidate:=f||'.'||left(l,n);
  if not exists(select 1 from public.staff where lower(id)=lower(candidate)) then new.id:=candidate;return new;end if;
 end loop;
 n:=2;
 while exists(select 1 from public.staff where lower(id)=lower(candidate||n)) loop n:=n+1;end loop;
 new.id:=candidate||n;return new;
end $$;
create trigger staff_identity before insert or update on public.staff for each row execute function private.staff_id();

create table public.meetings (
 id uuid primary key default gen_random_uuid(), staff_id text not null references public.staff(id), manager_id uuid not null references public.manager_profiles(id),
 created_by uuid not null default auth.uid() references public.manager_profiles(id),
 type text not null check(type in ('Routine','Special')), scheduled_at timestamptz not null,
 status text not null default 'Scheduled' check(status in ('Scheduled','Completed','Cancelled','Missed')),
 completed_on date, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), version int not null default 1,
 check((status='Completed' and completed_on is not null) or (status<>'Completed' and completed_on is null))
);
create unique index one_open_routine on public.meetings(staff_id) where type='Routine' and status='Scheduled';
create table public.meeting_notes (
 id uuid primary key default gen_random_uuid(), meeting_id uuid not null references public.meetings(id),
 body text not null check(length(trim(body)) between 1 and 20000), created_by uuid not null default auth.uid() references public.manager_profiles(id),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),version int not null default 1
);
create table public.gm_requests (
 id uuid primary key default gen_random_uuid(), staff_id text not null references public.staff(id),
 created_by uuid not null default auth.uid() references public.manager_profiles(id),requested_on date not null default (now() at time zone 'America/Chicago')::date,
 status text not null default 'Open' check(status in ('Open','Resolved','Withdrawn')),
 meeting_id uuid references public.meetings(id),version int not null default 1,updated_at timestamptz not null default now()
);
create unique index one_open_gm_request on public.gm_requests(staff_id) where status='Open';
create unique index one_request_per_meeting on public.gm_requests(meeting_id) where meeting_id is not null;
create table public.change_history (
 id bigint generated always as identity primary key, table_name text not null, record_id text not null,
 actor uuid, changed_at timestamptz not null default now(), before_value jsonb, after_value jsonb
);

create function private.validate_meeting() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='UPDATE' then
  if new.id<>old.id or new.created_by<>old.created_by or new.created_at<>old.created_at then raise exception 'Meeting ownership cannot change';end if;
  if new.version<>old.version then raise exception 'Reload this meeting before editing';end if;
  new.version:=old.version+1;
 end if;
 if new.status='Scheduled' and (not exists(select 1 from public.staff where id=new.staff_id and active) or not exists(select 1 from public.manager_profiles where id=new.manager_id and active)) then raise exception 'Open bookings require active staff and managers';end if;
 if new.status='Scheduled' and (TG_OP='INSERT' or new.scheduled_at is distinct from old.scheduled_at) and new.scheduled_at<now() then raise exception 'Choose a future meeting time';end if;
 if new.completed_on>(now() at time zone 'America/Chicago')::date then raise exception 'Completion date cannot be in the future';end if;
 if new.type='Special' and (TG_OP='INSERT' or new.type is distinct from old.type or new.manager_id is distinct from old.manager_id) then
  if not private.is_gm() or not exists(select 1 from public.manager_profiles where id=new.manager_id and active and is_gm) then raise exception 'Only the GM can create special meetings';end if;
 end if;
 if exists(select 1 from public.gm_requests where meeting_id=new.id and (staff_id<>new.staff_id or not exists(select 1 from public.manager_profiles where id=new.manager_id and is_gm and active))) then raise exception 'A linked GM meeting must retain its employee and active GM';end if;
 new.updated_at:=now();return new;
end $$;
create trigger meeting_validation before insert or update on public.meetings for each row execute function private.validate_meeting();
create function private.validate_note() returns trigger language plpgsql set search_path='' as $$
begin
 if new.id<>old.id or new.created_by<>old.created_by or new.meeting_id<>old.meeting_id or new.created_at<>old.created_at then raise exception 'Note ownership and meeting cannot change';end if;
 if new.version<>old.version then raise exception 'Reload this note before editing';end if;
 new.version:=old.version+1;new.updated_at:=now();return new;
end $$;
create trigger note_validation before update on public.meeting_notes for each row execute function private.validate_note();
create function private.validate_request() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='INSERT' then
  if new.status<>'Open' or not exists(select 1 from public.staff where id=new.staff_id and active) then raise exception 'New requests require active staff and an open status';end if;
 else
  if new.id<>old.id or new.staff_id<>old.staff_id or new.created_by<>old.created_by or new.requested_on<>old.requested_on then raise exception 'Request identity cannot change';end if;
  if new.version<>old.version then raise exception 'Reload this request before editing';end if;
  if pg_trigger_depth()=1 and auth.uid()<>old.created_by and (not private.is_gm() or new.status<>old.status) then raise exception 'Only the request creator can withdraw it';end if;
  new.version:=old.version+1;
 end if;
 if new.status='Resolved' and not exists(select 1 from public.meetings where id=new.meeting_id and status='Completed' and staff_id=new.staff_id) then raise exception 'Only a completed linked meeting resolves a request';end if;
 if new.meeting_id is not null and (TG_OP='INSERT' or new.meeting_id is distinct from old.meeting_id) and not exists(select 1 from public.meetings where id=new.meeting_id and status='Scheduled') then raise exception 'Choose an open booking to link';end if;
 if new.meeting_id is not null and not exists(select 1 from public.meetings m join public.manager_profiles p on p.id=m.manager_id where m.id=new.meeting_id and m.staff_id=new.staff_id and p.is_gm and m.status in ('Scheduled','Completed')) then raise exception 'Link an open or completed GM meeting for this employee';end if;
 new.updated_at:=now();return new;
end $$;
create trigger request_validation before insert or update on public.gm_requests for each row execute function private.validate_request();
create function private.meeting_effects() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='Completed' and (TG_OP='INSERT' or old.status<>'Completed') then
  update public.staff set priority=false,priority_set_at=null where id=new.staff_id;
  update public.gm_requests set status='Resolved' where meeting_id=new.id and status='Open';
 elsif TG_OP='UPDATE' and old.status='Completed' and new.status<>'Completed' then
  update public.gm_requests set status='Open',meeting_id=case when new.status='Scheduled' then new.id else null end where meeting_id=new.id and status='Resolved';
 end if;
 if new.status in ('Cancelled','Missed') then update public.gm_requests set meeting_id=null where meeting_id=new.id and status='Open';end if;
 return new;
end $$;
create trigger meeting_effects after insert or update on public.meetings for each row execute function private.meeting_effects();
create function private.audit_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.change_history(table_name,record_id,actor,before_value,after_value)
 values(TG_TABLE_NAME,new.id::text,auth.uid(),case when TG_OP='UPDATE' then to_jsonb(old) else null end,to_jsonb(new));return new;
end $$;
create trigger audit_meeting after insert or update on public.meetings for each row execute function private.audit_change();
create trigger audit_note after insert or update on public.meeting_notes for each row execute function private.audit_change();
create trigger audit_request after insert or update on public.gm_requests for each row execute function private.audit_change();
create trigger audit_staff after insert or update on public.staff for each row execute function private.audit_change();

alter table public.manager_profiles enable row level security;
alter table public.staff enable row level security;
alter table public.meetings enable row level security;
alter table public.meeting_notes enable row level security;
alter table public.gm_requests enable row level security;
alter table public.change_history enable row level security;
revoke all on public.manager_profiles,public.staff,public.meetings,public.meeting_notes,public.gm_requests,public.change_history from anon,authenticated;
grant select on public.manager_profiles,public.staff,public.meetings,public.meeting_notes,public.gm_requests,public.change_history to authenticated;
grant insert,update on public.staff,public.meetings,public.meeting_notes,public.gm_requests to authenticated;
create policy managers_read_profiles on public.manager_profiles for select to authenticated using(private.is_manager());
create policy managers_read_staff on public.staff for select to authenticated using(private.is_manager());
create policy admins_add_staff on public.staff for insert to authenticated with check(private.is_admin() and created_by=auth.uid());
create policy admins_edit_staff on public.staff for update to authenticated using(private.is_admin()) with check(private.is_admin());
create policy managers_read_meetings on public.meetings for select to authenticated using(private.is_manager());
create policy creators_add_meetings on public.meetings for insert to authenticated with check(private.is_manager() and created_by=auth.uid());
create policy creators_edit_meetings on public.meetings for update to authenticated using(private.is_manager() and created_by=auth.uid()) with check(private.is_manager() and created_by=auth.uid());
create policy managers_read_notes on public.meeting_notes for select to authenticated using(private.is_manager());
create policy creators_add_notes on public.meeting_notes for insert to authenticated with check(private.is_manager() and created_by=auth.uid());
create policy creators_edit_notes on public.meeting_notes for update to authenticated using(private.is_manager() and created_by=auth.uid()) with check(private.is_manager() and created_by=auth.uid());
create policy managers_read_requests on public.gm_requests for select to authenticated using(private.is_manager());
create policy creators_add_requests on public.gm_requests for insert to authenticated with check(private.is_manager() and created_by=auth.uid());
create policy creators_edit_requests on public.gm_requests for update to authenticated using(private.is_manager() and (created_by=auth.uid() or private.is_gm())) with check(private.is_manager() and (created_by=auth.uid() or private.is_gm()));
create policy managers_read_changes on public.change_history for select to authenticated using(private.is_manager());
-- Booking plus request linkage is a single transaction; permission failures roll it all back.
create function public.schedule_meeting(p_staff text,p_manager uuid,p_type text,p_at timestamptz,p_request uuid default null)
returns public.meetings language plpgsql security invoker set search_path='' as $$
declare booked public.meetings; linked uuid;
begin
 insert into public.meetings(staff_id,manager_id,type,scheduled_at) values(p_staff,p_manager,p_type,p_at) returning * into booked;
 if p_request is not null then
  update public.gm_requests set meeting_id=booked.id where id=p_request and staff_id=p_staff and status='Open' and meeting_id is null returning id into linked;
  if linked is null then raise exception 'Request changed or you cannot link it. Reload requests.';end if;
 end if;
 return booked;
end $$;
revoke all on function public.schedule_meeting(text,uuid,text,timestamptz,uuid) from public,anon;
grant execute on function public.schedule_meeting(text,uuid,text,timestamptz,uuid) to authenticated;
-- No client deletion, profile administration, ownership transfer, or audit editing permissions.
commit;
