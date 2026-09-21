begin;
-- No passwords or password hashes are returned by these interfaces. Until activation,
-- a username login has no employee/manager membership and therefore no workspace access.
create table private.username_accounts(
 user_id uuid primary key default gen_random_uuid(),
 staff_id text unique not null references public.staff(id),
 username text unique not null check(username=lower(username) and username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
 actor uuid not null references auth.users(id), submission uuid unique not null,
 state text not null default 'Reserved' check(state in ('Reserved','Ready','Activated')),
 reserved_at timestamptz not null default now(), expires_at timestamptz,
 temporary_hash text, activated_at timestamptz
);
alter table private.username_accounts enable row level security;
revoke all on private.username_accounts from public,anon,authenticated;
create function public.username_account_list() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not (private.is_admin() or private.is_gm()) then raise exception 'IT or GM access required';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('staff_id',staff_id,'username',username,'state',state,'expires_at',expires_at) order by username) from private.username_accounts),'[]');
end $$;
create function public.reserve_username_account(p_staff text,p_username text,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r private.username_accounts; u text:=lower(trim(p_username));
begin
 perform pg_advisory_xact_lock(61902028);
 if not (private.is_admin() or private.is_gm()) then raise exception 'IT or GM access required';end if;
 if p_submission is null or u is null or u !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then raise exception 'Use 3–32 letters, numbers, dots, underscores or hyphens for the username';end if;
 if not exists(select 1 from public.staff where id=p_staff and active) then raise exception 'Choose an active employee';end if;
 if exists(select 1 from private.employee_accounts where staff_id=p_staff) or exists(select 1 from public.manager_profiles where linked_staff_id=p_staff) or exists(select 1 from private.employee_invitations where staff_id=p_staff) then raise exception 'This employee already has an account or invitation';end if;
 if exists(select 1 from private.username_accounts where submission=p_submission) then raise exception 'This submission was already processed. Refresh the list; reissue a temporary password if needed';end if;
 select * into r from private.username_accounts where staff_id=p_staff for update;
 if found then
  if r.username<>u then raise exception 'Keep the existing username for this employee';end if;
  if r.state='Activated' then raise exception 'This account is already activated';end if;
  if r.state='Reserved' and r.reserved_at>now()-interval '2 minutes' then raise exception 'Account creation is still in progress. Wait two minutes before retrying';end if;
  update private.username_accounts set actor=auth.uid(),submission=p_submission,state='Reserved',reserved_at=now(),temporary_hash=null,expires_at=null where user_id=r.user_id returning * into r;
 else
  if exists(select 1 from private.username_accounts where username=u) then raise exception 'This username is already taken';end if;
  insert into private.username_accounts(staff_id,username,actor,submission) values(p_staff,u,auth.uid(),p_submission) returning * into r;
 end if;
 perform private.schedule_audit('reserve_username_account',p_staff,null,jsonb_build_object('username',u));
 return jsonb_build_object('user_id',r.user_id,'username',r.username,'email',r.username||'@users.shift.invalid');
end $$;
-- The service captures the actual Auth hash only after provisioning the password.
create function public.finish_username_account(p_submission uuid) returns void language plpgsql security definer set search_path='' as $$
declare r private.username_accounts; h text;
begin
 perform pg_advisory_xact_lock(61902028);
 select * into strict r from private.username_accounts where submission=p_submission for update;
 if r.state<>'Reserved' then raise exception 'Account operation has changed';end if;
 if not exists(select 1 from public.manager_profiles where id=r.actor and active and (is_admin or is_gm)) or not exists(select 1 from public.staff where id=r.staff_id and active) then raise exception 'Account access changed. IT must review this account';end if;
 select encrypted_password into h from auth.users where id=r.user_id and lower(email)=r.username||'@users.shift.invalid';
 if coalesce(h,'')='' then raise exception 'Authentication account is not ready';end if;
 update private.username_accounts set state='Ready',temporary_hash=h,expires_at=now()+interval '7 days' where user_id=r.user_id;
end $$;
create function public.username_account_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r private.username_accounts;
begin
 select * into r from private.username_accounts where user_id=auth.uid();
 if not found then return jsonb_build_object('required',false);end if;
 return jsonb_build_object('username',r.username,'required',r.state<>'Activated','ready',r.state='Ready' and r.expires_at>now(),'expires_at',r.expires_at);
end $$;
create function public.activate_username_account() returns void language plpgsql security definer set search_path='' as $$
declare r private.username_accounts; h text;
begin
 perform pg_advisory_xact_lock(61902028);
 select * into strict r from private.username_accounts where user_id=auth.uid() for update;
 if r.state='Activated' then return;end if;
 if r.state<>'Ready' or r.expires_at<=now() then raise exception 'Ask IT or the GM for a new temporary password';end if;
 select encrypted_password into h from auth.users where id=auth.uid();
 if coalesce(h,'')='' or h=r.temporary_hash then raise exception 'Set your own password before entering the workspace';end if;
 if not exists(select 1 from public.staff where id=r.staff_id and active) or not exists(select 1 from public.manager_profiles where id=r.actor and active and (is_admin or is_gm)) then raise exception 'Access changed. Ask IT or the GM to review this account';end if;
 if exists(select 1 from private.employee_accounts where staff_id=r.staff_id) or exists(select 1 from public.manager_profiles where linked_staff_id=r.staff_id or id=r.user_id) or exists(select 1 from private.employee_invitations where staff_id=r.staff_id) then raise exception 'This employee already has another account. Ask IT to review';end if;
 insert into private.employee_accounts(id,staff_id) values(r.user_id,r.staff_id);
 update private.username_accounts set state='Activated',activated_at=now(),temporary_hash=null where user_id=r.user_id;
 perform private.schedule_audit('activate_username_account',r.staff_id,null,jsonb_build_object('username',r.username));
end $$;
-- Do not allow a parallel email invitation to race a reserved username account.
create function private.reject_reserved_username_invitation() returns trigger language plpgsql security definer set search_path='' as $$begin
 perform pg_advisory_xact_lock(61902028);
 if exists(select 1 from private.username_accounts where staff_id=new.staff_id) then raise exception 'This employee has a username account';end if;
 return new;
end $$;
create trigger reject_reserved_username_invitation before insert on private.employee_invitations for each row execute function private.reject_reserved_username_invitation();
revoke all on function public.username_account_list(),public.reserve_username_account(text,text,uuid),public.username_account_status(),public.activate_username_account(),public.finish_username_account(uuid),private.reject_reserved_username_invitation() from public,anon,authenticated;
grant execute on function public.username_account_list(),public.reserve_username_account(text,text,uuid),public.username_account_status(),public.activate_username_account() to authenticated;
grant execute on function public.finish_username_account(uuid) to service_role;
commit;
