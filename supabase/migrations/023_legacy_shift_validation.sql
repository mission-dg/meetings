begin;
-- Let managers repair legacy draft errors individually. New or changed intervals
-- must be valid; unchanged legacy intervals remain release-blocking issues.
create or replace function private.check_work_shift_times() returns trigger language plpgsql set search_path='' as $$
declare s jsonb; starts timestamptz; ends timestamptz; label text;
begin
 if TG_OP='UPDATE' and new.shifts is not distinct from old.shifts then return new;end if;
 for s in select value from jsonb_array_elements(new.shifts) loop
  if TG_OP='UPDATE' and new.state in ('Draft','Attention') and old.state in ('Draft','Attention') and exists(
   select 1 from jsonb_array_elements(old.shifts) p where p->>'id'=s->>'id' and p->>'person_id'=s->>'person_id' and p->>'start'=s->>'start' and p->>'end'=s->>'end'
  ) then continue;end if;
  label:=private.person_name(s->>'person_id')||': ';
  starts:=(s->>'start')::timestamptz;ends:=(s->>'end')::timestamptz;
  if starts is null or ends is null or not isfinite(starts) or not isfinite(ends) then raise exception '%Choose valid start and end times',label;end if;
  if ends<=starts then raise exception '%End time must be after start time. For an overnight shift, choose the following date.',label;end if;
  if ends-starts>interval '12 hours' then raise exception '%A shift cannot exceed 12 hours.',label;end if;
 end loop;
 return new;
end $$;
commit;
