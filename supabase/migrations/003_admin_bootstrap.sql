-- Allow IT Admin setup before the first GM is appointed.
begin;
create table private.tracker_setup(singleton boolean primary key default true check(singleton),gm_initialized boolean not null default false);
revoke all on private.tracker_setup from public,anon,authenticated;
insert into private.tracker_setup values(true,exists(select 1 from public.manager_profiles where active and is_gm));
create or replace function private.require_gm() returns trigger language plpgsql security definer set search_path='' as $$
declare initialized boolean; gm_count integer;
begin
 select gm_initialized into initialized from private.tracker_setup where singleton for update;
 select count(*) into gm_count from public.manager_profiles where active and is_gm;
 if gm_count=1 then
  update private.tracker_setup set gm_initialized=true where singleton;
 elsif initialized or gm_count>1 then
  raise exception 'Exactly one active manager must be GM';
 end if;
 return null;
end $$;
commit;
