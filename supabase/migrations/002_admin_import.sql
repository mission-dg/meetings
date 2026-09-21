begin;
alter table public.manager_profiles add column version integer not null default 1;
create trigger audit_profile after insert or update on public.manager_profiles for each row execute function private.audit_change();
create function public.admin_update_manager(p_id uuid,p_name text,p_active boolean,p_admin boolean,p_gm boolean,p_version integer)
returns void language plpgsql security definer set search_path='' as $$
declare old_profile public.manager_profiles;
begin
 perform pg_advisory_xact_lock(61902027);
 if not private.is_admin() then raise exception 'IT Admin access required';end if;
 select * into old_profile from public.manager_profiles where id=p_id for update;
 if not found or old_profile.version<>p_version then raise exception 'Account changed. Refresh before saving.';end if;
 if p_name is null or length(trim(p_name)) not between 1 and 120 or p_active is null or p_admin is null or p_gm is null then raise exception 'Provide a name and valid account settings';end if;
 if p_id=auth.uid() and (not p_active or not p_admin) then raise exception 'Another IT Admin must remove your access';end if;
 if old_profile.is_admin and old_profile.active and not(p_active and p_admin) and not exists(select 1 from public.manager_profiles where active and is_admin and id<>p_id) then raise exception 'Keep at least one active IT Admin';end if;
 if p_gm and not p_active then raise exception 'The GM must be active';end if;
 if old_profile.is_gm and old_profile.active and not(p_active and p_gm) then raise exception 'Assign another active manager as GM first';end if;
 if p_gm and p_active and not(old_profile.is_gm and old_profile.active) then
  if exists(select 1 from public.gm_requests r join public.meetings m on m.id=r.meeting_id join public.manager_profiles p on p.id=m.manager_id where r.status='Open' and m.status='Scheduled' and p.is_gm and p.id<>p_id) then raise exception 'Resolve or cancel the current GM’s linked open bookings before changing GM';end if;
  update public.manager_profiles set is_gm=false,version=version+1 where is_gm and id<>p_id;
 end if;
 update public.manager_profiles set name=trim(p_name),active=p_active,is_admin=p_admin,is_gm=p_gm,version=version+1 where id=p_id;
end $$;
create function public.admin_register_manager(p_id uuid,p_name text,p_admin boolean default false)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(61902027);
 if not private.is_admin() then raise exception 'IT Admin access required';end if;
 if p_name is null or length(trim(p_name)) not between 1 and 120 or p_admin is null then raise exception 'Provide a valid name';end if;
 insert into public.manager_profiles(id,name,is_admin) values(p_id,trim(p_name),p_admin);
end $$;
create table private.staff_imports(batch_id uuid primary key,actor uuid not null,payload jsonb not null,result jsonb not null);
revoke all on private.staff_imports from public,anon,authenticated;
create function public.admin_import_staff(p_batch uuid,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior private.staff_imports; r jsonb; f text; l text; dep text; act boolean; staff_id text; added int:=0; skipped int:=0; result jsonb;
begin
 perform pg_advisory_xact_lock(61902026);
 if not private.is_admin() then raise exception 'IT Admin access required';end if;
 if p_batch is null or p_rows is null or jsonb_typeof(p_rows)<>'array' then raise exception 'Choose a valid import file';end if;
 select * into prior from private.staff_imports where batch_id=p_batch;
 if found then
  if prior.actor<>auth.uid() or prior.payload<>p_rows then raise exception 'Import changed. Preview again.';end if;
  return prior.result;
 end if;
 if jsonb_array_length(p_rows) not between 1 and 500 then raise exception 'Import between 1 and 500 employees at a time';end if;
 for r in select value from jsonb_array_elements(p_rows) loop
  f:=trim(r->>'first_name');l:=trim(r->>'last_name');dep:=r->>'department';
  if f is null or l is null or length(f) not between 1 and 100 or length(l) not between 1 and 100 or dep is null or dep not in ('FOH','BOH') or jsonb_typeof(r->'active') is distinct from 'boolean' then raise exception 'Every row needs first name, last name, FOH/BOH, and an active status';end if;
  act:=(r->>'active')::boolean;
  -- Names across either department are skipped to avoid duplicating transfers or inactive staff.
  if exists(select 1 from public.staff where lower(trim(first_name))=lower(f) and lower(trim(last_name))=lower(l)) then skipped:=skipped+1;continue;end if;
  insert into public.staff(first_name,last_name,department,active,created_by) values(f,l,dep,act,auth.uid()) returning id into staff_id;
  added:=added+1;
 end loop;
 result:=jsonb_build_object('added',added,'skipped',skipped);
 insert into private.staff_imports values(p_batch,auth.uid(),p_rows,result);
 return result;
end $$;
revoke all on function public.admin_update_manager(uuid,text,boolean,boolean,boolean,integer),public.admin_register_manager(uuid,text,boolean),public.admin_import_staff(uuid,jsonb) from public,anon;
grant execute on function public.admin_update_manager(uuid,text,boolean,boolean,boolean,integer),public.admin_register_manager(uuid,text,boolean),public.admin_import_staff(uuid,jsonb) to authenticated;
commit;
