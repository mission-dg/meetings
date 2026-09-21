-- Qualification reminders are advisory. Overlap, availability and training-link checks remain enforced.
begin;
create or replace function private.shift_issues(p_shifts jsonb,p_week date) returns text[] language plpgsql stable security definer set search_path='' as $$
declare issues text[]:='{}';s jsonb;o jsonb;t record;p text;starts timestamptz;ends timestamptz;job uuid;why text;seen text[]:='{}';
begin
 if jsonb_typeof(p_shifts) is distinct from 'array' or jsonb_array_length(p_shifts)>1000 then return array['A schedule must contain at most 1,000 shifts'];end if;
 for s in select value from jsonb_array_elements(p_shifts) loop
  begin
   perform (s->>'id')::uuid;p:=s->>'person_id';starts:=(s->>'start')::timestamptz;ends:=(s->>'end')::timestamptz;job:=(s->>'job_id')::uuid;
   if s->>'id' is null or p is null or starts is null or ends is null or (s->>'slot')::int<1 or s->>'slot' is null then raise exception 'Missing shift fields';end if;
   if s->>'id'=any(seen) then raise exception 'Duplicate shift ID';end if;seen:=array_append(seen,s->>'id');
   if ends<=starts or ends-starts>interval '12 hours' then raise exception 'Shift end must be after start and no more than 12 hours later';end if;
   if (starts at time zone 'America/Chicago')::date<p_week or (starts at time zone 'America/Chicago')::date>=p_week+7 then raise exception 'Shift must start in this scheduling week';end if;
   if exists(select 1 from private.schedule_weeks ww join private.schedule_revisions rr on rr.id=ww.published_id cross join lateral jsonb_array_elements(rr.shifts) xx where ww.week_start<>p_week and xx->>'id'=s->>'id') then raise exception 'Shift ID is already used in another week';end if;
   if not private.person_active(p) then raise exception 'Choose an active person on the work roster';end if;
   if private.person_is_shl(p) then
    if job is not null then raise exception 'Managers must be scheduled as SHL';end if;
   else
    if not exists(select 1 from public.training_positions where id=job and active) then raise exception 'Choose an active job';end if;
   end if;
   why:=private.person_conflict(p,starts,ends);if why is not null then raise exception '%',why;end if;
   if exists(select 1 from jsonb_array_elements(p_shifts) x where x->>'id'<>s->>'id' and x->>'person_id'=p and (x->>'start')::timestamptz<ends and (x->>'end')::timestamptz>starts) then raise exception 'Overlapping work shifts';end if;
   if exists(select 1 from private.schedule_weeks w join private.schedule_revisions r on r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) x where w.week_start<>p_week and x->>'person_id'=p and (x->>'start')::timestamptz<ends and (x->>'end')::timestamptz>starts) then raise exception 'Overlap with another published week';end if;
  exception when others then issues:=array_append(issues,private.person_name(s->>'person_id')||': '||sqlerrm);end;
 end loop;return issues;
end $$;


-- Reject invalid draft saves as well as release and trade attempts.
create function private.check_work_shift_times() returns trigger language plpgsql set search_path='' as $$
declare s jsonb; starts timestamptz; ends timestamptz;
begin
 if TG_OP='UPDATE' and new.shifts is not distinct from old.shifts then return new;end if;
 for s in select value from jsonb_array_elements(new.shifts) loop
  starts:=(s->>'start')::timestamptz;ends:=(s->>'end')::timestamptz;
  if starts is null or ends is null or not isfinite(starts) or not isfinite(ends) then raise exception 'Choose valid start and end times';end if;
  if ends<=starts then raise exception 'End time must be after start time. For an overnight shift, choose the following date.';end if;
  if ends-starts>interval '12 hours' then raise exception 'A shift cannot exceed 12 hours.';end if;
 end loop;
 return new;
end $$;
revoke all on function private.check_work_shift_times() from public,anon,authenticated;
create trigger check_work_shift_times before insert or update of shifts on private.schedule_revisions for each row execute function private.check_work_shift_times();
commit;
