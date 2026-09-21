begin;
alter table public.staff drop constraint staff_department_check;
alter table public.staff add constraint staff_department_check check(department in ('FOH','BOH','Catering'));
create or replace function public.admin_import_staff(p_batch uuid,p_rows jsonb)
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
  if f is null or l is null or length(f) not between 1 and 100 or length(l) not between 1 and 100 or dep is null or dep not in ('FOH','BOH','Catering') or jsonb_typeof(r->'active') is distinct from 'boolean' then raise exception 'Every row needs first name, last name, FOH/BOH/Catering, and an active status';end if;
  act:=(r->>'active')::boolean;
  -- Names across all departments are skipped to avoid duplicating transfers or inactive staff.
  if exists(select 1 from public.staff where lower(trim(first_name))=lower(f) and lower(trim(last_name))=lower(l)) then skipped:=skipped+1;continue;end if;
  insert into public.staff(first_name,last_name,department,active,created_by) values(f,l,dep,act,auth.uid()) returning id into staff_id;
  added:=added+1;
 end loop;
 result:=jsonb_build_object('added',added,'skipped',skipped);
 insert into private.staff_imports values(p_batch,auth.uid(),p_rows,result);
 return result;
end $$;
commit;
