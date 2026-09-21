begin;
create function public.admin_remove_staff(p_staff text,p_phrase text,p_confirmation text)
returns void language plpgsql security definer set search_path='' as $$
declare employee public.staff;
begin
 if not private.is_admin() then raise exception 'IT Admin access required';end if;
 select * into employee from public.staff where id=p_staff for update;
 if not found then raise exception 'Employee not found. Refresh the staff directory.';end if;
 if p_phrase is distinct from 'Remove '||employee.first_name||' '||employee.last_name or p_confirmation is distinct from 'Confirm' then raise exception 'Type the exact employee removal phrase and Confirm. If their name changed, reopen this window.';end if;
 update public.staff set active=false where id=p_staff;
end $$;
create function public.set_it_access(p_id uuid,p_admin boolean,p_version integer)
returns void language plpgsql security definer set search_path='' as $$
declare target public.manager_profiles;
begin
 perform pg_advisory_xact_lock(61902027);
 if not (private.is_admin() or private.is_gm()) then raise exception 'IT Admin or GM access required';end if;
 select * into target from public.manager_profiles where id=p_id for update;
 if not found or p_version is null or target.version<>p_version then raise exception 'Account changed. Refresh before saving.';end if;
 if p_admin is null then raise exception 'Choose whether this account has IT Admin access';end if;
 if p_admin and not target.active then raise exception 'Activate this account before granting IT Admin access';end if;
 if target.is_admin and target.active and not p_admin and not exists(select 1 from public.manager_profiles where active and is_admin and id<>p_id) then raise exception 'Keep at least one active IT Admin. Promote another active account first.';end if;
 if target.is_admin=p_admin then return;end if;
 update public.manager_profiles set is_admin=p_admin,version=version+1 where id=p_id;
end $$;
revoke all on function public.admin_remove_staff(text,text,text),public.set_it_access(uuid,boolean,integer) from public,anon;
grant execute on function public.admin_remove_staff(text,text,text),public.set_it_access(uuid,boolean,integer) to authenticated;
commit;
