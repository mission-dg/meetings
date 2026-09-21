begin;
alter table public.staff add column is_trainer boolean not null default false;
create table public.training_sessions (
 id uuid primary key default gen_random_uuid(), staff_id text not null references public.staff(id),
 trainer_id text not null references public.staff(id), shift integer not null check(shift in (1,2)), scheduled_at timestamptz not null,
 status text not null default 'Scheduled' check(status in ('Scheduled','Completed','Missed','Cancelled')),
 created_by uuid not null default auth.uid() references public.manager_profiles(id),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),version integer not null default 1,
 check(staff_id<>trainer_id)
);
create function private.validate_training() returns trigger language plpgsql security definer set search_path='' as $$
declare local_start timestamp:=new.scheduled_at at time zone 'America/Chicago'; sunday boolean:=extract(dow from local_start)=0;
begin
 if TG_OP='UPDATE' then
  if new.id<>old.id or new.created_by<>old.created_by or new.created_at<>old.created_at then raise exception 'Training ownership cannot change';end if;
  if new.version<>old.version then raise exception 'Reload this training session before editing';end if;
  new.version:=old.version+1;
 end if;
 if TG_OP='INSERT' or new.scheduled_at is distinct from old.scheduled_at then
  if local_start::time < (case when sunday then time '11:30' else time '11:00' end) or local_start::time >= (case when sunday then time '20:00' else time '21:00' end) then raise exception 'Training must start during opening hours: Sunday 11:30 AM–8 PM; other days 11 AM–9 PM';end if;
 end if;
 if new.status='Scheduled' then
  if not exists(select 1 from public.staff where id=new.staff_id and active) then raise exception 'Choose an active employee';end if;
  if not exists(select 1 from public.staff where id=new.trainer_id and active and is_trainer) then raise exception 'Choose an active trainer';end if;
  if (TG_OP='INSERT' or new.scheduled_at is distinct from old.scheduled_at) and new.scheduled_at<now() then raise exception 'Choose a future start time';end if;
 end if;
 new.updated_at:=now();return new;
end $$;
create trigger training_validation before insert or update on public.training_sessions for each row execute function private.validate_training();
create trigger audit_training after insert or update on public.training_sessions for each row execute function private.audit_change();
alter table public.training_sessions enable row level security;
revoke all on public.training_sessions from anon,authenticated;
grant select,insert,update on public.training_sessions to authenticated;
create policy managers_read_training on public.training_sessions for select to authenticated using(private.is_manager());
create policy creators_add_training on public.training_sessions for insert to authenticated with check(private.is_manager() and created_by=auth.uid());
create policy creators_edit_training on public.training_sessions for update to authenticated using(private.is_manager() and created_by=auth.uid()) with check(private.is_manager() and created_by=auth.uid());
commit;
