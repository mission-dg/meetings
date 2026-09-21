begin;
alter table private.username_accounts add column initial_role text not null default 'employee' check(initial_role in ('employee','manager'));
alter table private.username_accounts add column version integer not null default 1;
create table private.username_history(username text primary key,user_id uuid not null references private.username_accounts(user_id));
insert into private.username_history select username,user_id from private.username_accounts;
alter table private.username_history enable row level security;
revoke all on private.username_history from public,anon,authenticated;
-- Revoked JWTs must not regain access after a reset. Check the actual Auth session,
-- not user-editable metadata or the issued-at time of a refreshed token.
create function private.username_session_current(p_user uuid,p_since timestamptz) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.sessions s where s.user_id=p_user and s.id::text=(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'session_id') and s.created_at>=p_since)
$$;
create function private.credentials_ready() returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from private.username_accounts a where a.user_id=auth.uid() and (a.state<>'Activated' or not private.username_session_current(a.user_id,a.reserved_at)))
$$;
create or replace function private.is_manager() returns boolean language sql stable security definer set search_path='' as $$select private.credentials_ready() and exists(select 1 from public.manager_profiles where id=auth.uid() and active)$$;
create or replace function private.is_admin() returns boolean language sql stable security definer set search_path='' as $$select private.credentials_ready() and exists(select 1 from public.manager_profiles where id=auth.uid() and active and is_admin)$$;
create or replace function private.is_gm() returns boolean language sql stable security definer set search_path='' as $$select private.credentials_ready() and exists(select 1 from public.manager_profiles where id=auth.uid() and active and is_gm)$$;
create or replace function private.employee_staff() returns text language sql stable security definer set search_path='' as $$select a.staff_id from private.employee_accounts a join public.staff s on s.id=a.staff_id where private.credentials_ready() and a.id=auth.uid() and a.active and s.active$$;
create or replace function private.is_ca() returns boolean language sql stable security definer set search_path='' as $$select private.credentials_ready() and exists(select 1 from private.employee_accounts a join public.staff s on s.id=a.staff_id where a.id=auth.uid() and a.active and a.is_ca and s.active)$$;
create or replace function public.username_account_list() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not (private.is_admin() or private.is_gm()) then raise exception 'IT or GM access required';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',a.user_id,'staff_id',a.staff_id,'username',a.username,'state',a.state,'expires_at',a.expires_at,'version',a.version,'role',case when m.active and m.is_admin then 'it' when m.active then 'manager' when a.activated_at is null then a.initial_role else 'employee' end,'active',s.active and (a.activated_at is null or e.active)) order by username) from private.username_accounts a join public.staff s on s.id=a.staff_id left join private.employee_accounts e on e.id=a.user_id left join public.manager_profiles m on m.id=a.user_id),'[]');
end $$;
create function public.prepare_username_login(p_staff text,p_username text,p_role text,p_target uuid,p_version integer,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r private.username_accounts; u text:=lower(trim(p_username)); existing_id uuid; prior_name text;
begin
 perform pg_advisory_xact_lock(61902028);
 if not (private.is_admin() or private.is_gm()) then raise exception 'IT or GM access required';end if;
 if p_submission is null or u is null or u !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then raise exception 'Use 3–32 letters, numbers, dots, underscores or hyphens for the username';end if;
 if p_role is null or p_role not in ('employee','manager') then raise exception 'Choose Employee or Manager';end if;
 if exists(select 1 from private.scheduler_submissions where id=p_submission) then raise exception 'This submission was already processed. Refresh the account list';end if;
 if p_target is null then
  if exists(select 1 from private.employee_accounts where staff_id=p_staff) or exists(select 1 from public.manager_profiles where linked_staff_id=p_staff) or exists(select 1 from private.employee_invitations where staff_id=p_staff) then raise exception 'This person already has an account or invitation';end if;
  if exists(select 1 from private.username_accounts where staff_id=p_staff) then raise exception 'This person already has a username account. Edit that account';end if;
  if not exists(select 1 from public.staff where id=p_staff and active) then raise exception 'Choose an active teammate';end if;
 else
  select * into strict r from private.username_accounts where user_id=p_target for update;
  if p_target=auth.uid() then raise exception 'Use Change password for your own login; another GM or IT can change your username';end if;
  if r.version is distinct from p_version then raise exception 'Account changed. Refresh and try again';end if;
  if r.state='Reserved' then raise exception 'Account setup is in progress or needs IT review. Do not retry an uncertain operation';end if;
  if not exists(select 1 from public.staff where id=r.staff_id and active) or (r.activated_at is not null and not exists(select 1 from private.employee_accounts where id=r.user_id and active)) then raise exception 'Reactivate this person and account before resetting credentials';end if;
  -- Credentials never change existing roles or reactivate disabled accounts.
  p_role:=r.initial_role; p_staff:=r.staff_id; prior_name:=r.username;
 end if;
 select user_id into existing_id from private.username_history where username=u;
 if existing_id is not null and existing_id is distinct from r.user_id then raise exception 'This username is already reserved';end if;
 if p_target is null then
  insert into private.username_accounts(staff_id,username,actor,submission,initial_role) values(p_staff,u,auth.uid(),p_submission,p_role) returning * into r;
 else
  update private.username_accounts set username=u,actor=auth.uid(),submission=p_submission,state='Reserved',reserved_at=clock_timestamp(),temporary_hash=null,expires_at=null,version=version+1 where user_id=r.user_id returning * into r;
 end if;
 insert into private.username_history values(u,r.user_id) on conflict(username) do nothing;
 delete from private.calendar_tokens where user_id=r.user_id;
 perform private.schedule_audit(case when p_target is null then 'create_username_login' else 'reset_username_login' end,r.user_id::text,jsonb_build_object('username',prior_name),jsonb_build_object('username',u,'staff_id',r.staff_id));
 insert into private.scheduler_submissions values(p_submission,auth.uid(),'prepare_username_login',jsonb_build_object('user_id',r.user_id),'{}');
 return jsonb_build_object('user_id',r.user_id,'username',u,'email',u||'@users.shift.invalid');
end $$;
create or replace function public.finish_username_account(p_submission uuid) returns void language plpgsql security definer set search_path='' as $$
declare r private.username_accounts; h text;
begin
 perform pg_advisory_xact_lock(61902028);
 select * into strict r from private.username_accounts where submission=p_submission for update;
 if r.state<>'Reserved' then raise exception 'Account operation has changed';end if;
 if not exists(select 1 from public.manager_profiles where id=r.actor and active and (is_admin or is_gm)) or not exists(select 1 from public.staff where id=r.staff_id and active) then raise exception 'Account access changed. IT must review this account';end if;
 select encrypted_password into h from auth.users where id=r.user_id and lower(email)=r.username||'@users.shift.invalid';
 if coalesce(h,'')='' then raise exception 'Authentication account is not ready';end if;
 update private.username_accounts set state='Ready',temporary_hash=h,expires_at=now()+interval '7 days',version=version+1 where user_id=r.user_id;
end $$;
create or replace function public.username_account_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r private.username_accounts; fresh boolean;
begin
 select * into r from private.username_accounts where user_id=auth.uid();
 if not found then return jsonb_build_object('required',false);end if;
 fresh:=private.username_session_current(r.user_id,r.reserved_at);
 return jsonb_build_object('username',r.username,'required',r.state<>'Activated' or not fresh,'ready',r.state='Ready' and r.expires_at>now() and fresh,'expires_at',r.expires_at);
end $$;
create or replace function public.activate_username_account() returns void language plpgsql security definer set search_path='' as $$
declare r private.username_accounts; h text;s public.staff;
begin
 perform pg_advisory_xact_lock(61902028);
 select * into strict r from private.username_accounts where user_id=auth.uid() for update;
 if not private.username_session_current(r.user_id,r.reserved_at) then raise exception 'Sign out and sign in with the latest temporary password';end if;
 if r.state='Activated' then return;end if;
 if r.state<>'Ready' or r.expires_at<=now() then raise exception 'Ask IT or the GM for a new temporary password';end if;
 select encrypted_password into h from auth.users where id=auth.uid();
 if coalesce(h,'')='' or h=r.temporary_hash then raise exception 'Set your own password before entering the workspace';end if;
 select * into strict s from public.staff where id=r.staff_id;
 if not s.active or not exists(select 1 from public.manager_profiles where id=r.actor and active and (is_admin or is_gm)) then raise exception 'Access changed. Ask IT or the GM to review this account';end if;
 if r.activated_at is null then
  if exists(select 1 from private.employee_accounts where staff_id=r.staff_id) or exists(select 1 from public.manager_profiles where linked_staff_id=r.staff_id or id=r.user_id) or exists(select 1 from private.employee_invitations where staff_id=r.staff_id) then raise exception 'This person already has another account. Ask IT to review';end if;
  insert into private.employee_accounts(id,staff_id) values(r.user_id,r.staff_id);
  if r.initial_role='manager' then insert into public.manager_profiles(id,name,linked_staff_id,on_roster) values(r.user_id,s.first_name||' '||s.last_name,r.staff_id,true);end if;
 else
  if not exists(select 1 from private.employee_accounts where id=r.user_id and active) then raise exception 'Account disabled. Ask IT to review';end if;
 end if;
 update private.username_accounts set state='Activated',activated_at=coalesce(activated_at,now()),temporary_hash=null,version=version+1 where user_id=r.user_id;
 perform private.schedule_audit('activate_username_account',r.staff_id,null,jsonb_build_object('username',r.username));
end $$;
-- Supersede the old employee-only creation API.
revoke all on function public.reserve_username_account(text,text,uuid) from authenticated;
revoke all on function public.prepare_username_login(text,text,text,uuid,integer,uuid),private.credentials_ready(),private.username_session_current(uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.prepare_username_login(text,text,text,uuid,integer,uuid) to authenticated;
commit;
