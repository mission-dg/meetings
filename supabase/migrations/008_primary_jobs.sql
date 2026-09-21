begin;
alter table public.staff add column primary_job_id uuid references public.training_positions(id);
create function private.validate_primary_job() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='staff' then
  if new.primary_job_id is not null and (TG_OP='INSERT' or new.primary_job_id is distinct from old.primary_job_id or new.department is distinct from old.department) then
   if not exists(select 1 from public.training_positions where id=new.primary_job_id and active and department=new.department) then raise exception 'Choose an active primary job in this employee’s position group';end if;
  end if;
 else
  if new.department is distinct from old.department and exists(select 1 from public.staff where primary_job_id=new.id and department<>new.department) then raise exception 'Reassign employees with this primary job before changing its position group';end if;
 end if;
 return new;
end $$;
create trigger staff_primary_job_validation before insert or update on public.staff for each row execute function private.validate_primary_job();
create trigger training_job_primary_group_validation before update on public.training_positions for each row execute function private.validate_primary_job();
commit;
