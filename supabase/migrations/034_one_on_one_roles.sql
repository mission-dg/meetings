begin;
-- A management login alone does not make someone a salaried 1:1 host.
create function private.one_on_one_host(p_manager uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.manager_profiles m where m.id=p_manager and m.active
 and private.person_employment(case when m.linked_staff_id is null then 'm:'||m.id else 's:'||m.linked_staff_id end)='Salaried')
$$;
create function private.guard_one_on_one_roles() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 -- Preserve historical outcomes and allow unsuitable old bookings to be cancelled.
 if new.status<>'Scheduled' then return new;end if;
 if not private.one_on_one_host(new.manager_id) then raise exception 'Choose an active sSHL to lead the 1:1. hSHL, CA and TA cannot be the meeting manager';end if;
 if exists(select 1 from public.manager_profiles m where m.linked_staff_id=new.staff_id and private.one_on_one_host(m.id))
 or private.staff_shl_code(new.staff_id)='sSHL' then raise exception 'Choose a non-sSHL teammate for this 1:1';end if;
 return new;
end $$;
create trigger one_on_one_roles before insert or update on public.meetings for each row execute function private.guard_one_on_one_roles();
alter function public.scheduler_read(date) rename to scheduler_read_before_one_on_one_roles;
create function public.scheduler_read(p_week date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 r:=public.scheduler_read_before_one_on_one_roles(p_week);
 return jsonb_set(r,'{meeting_managers}',coalesce((select jsonb_agg(m) from jsonb_array_elements(coalesce(r->'meeting_managers','[]')) m where private.one_on_one_host((m->>'id')::uuid)),'[]'));
end $$;
revoke all on function private.one_on_one_host(uuid),private.guard_one_on_one_roles() from public;
revoke all on function public.scheduler_read_before_one_on_one_roles(date) from public,anon,authenticated;
revoke all on function public.scheduler_read(date) from public,anon;
grant execute on function public.scheduler_read(date) to authenticated;
commit;
