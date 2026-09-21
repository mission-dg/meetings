begin;
-- The edge endpoint supplies a bearer subscription token, never a user ID.
create function public.calendar_feed_data(p_token text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid;s text;linked text;m boolean;p text;events jsonb;lo timestamptz:=now()-interval '90 days';hi timestamptz:=now()+interval '18 months';
begin
 if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return null;end if;
 select user_id into u from private.calendar_tokens where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if u is null then return null;end if;
 select exists(select 1 from public.manager_profiles where id=u and active) into m;
 select a.staff_id into s from private.employee_accounts a join public.staff st on st.id=a.staff_id where a.id=u and a.active and st.active;
 if not m and s is null then return null;end if;
 select linked_staff_id into linked from public.manager_profiles where id=u and active;
 p:=case when m then case when linked is null then 'm:'||u::text else 's:'||linked end else 's:'||s end;
 select coalesce(jsonb_agg(e),'[]') into events from (
  select jsonb_build_object('uid','shift-'||(x->>'id'),'start',x->>'start','end',x->>'end','title','Work · '||coalesce(j.name,'SHL')||' · Shift '||(x->>'slot'),'status','CONFIRMED','sequence',(select count(*) from private.schedule_revisions z where z.week_id=w.id and z.state='Published'),'updated',r.released_at) e
  from private.schedule_weeks w join private.schedule_revisions r on r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) x left join public.training_positions j on j.id=(x->>'job_id')::uuid
  where x->>'person_id'=p and (x->>'end')::timestamptz>=lo and (x->>'start')::timestamptz<hi
  union all
  select jsonb_build_object('uid','meeting-'||a.id,'start',a.scheduled_at,'title',a.type||' meeting · '||private.person_name('s:'||a.staff_id),'status',case when a.status in ('Cancelled','Missed') then 'CANCELLED' else 'CONFIRMED' end,'sequence',a.version,'updated',a.updated_at)
  from public.meetings a where (a.staff_id=s or a.manager_id=u) and a.scheduled_at>=lo and a.scheduled_at<hi
  union all
  select jsonb_build_object('uid','training-'||t.id,'start',t.scheduled_at,'end',t.ends_at,'title',private.person_name('s:'||t.trainer_id)||' Training '||private.person_name('s:'||t.staff_id),'status',case when t.status in ('Cancelled','Missed') then 'CANCELLED' else 'CONFIRMED' end,'sequence',t.version,'updated',t.updated_at)
  from public.training_sessions t where (t.staff_id=s or t.trainer_id=s) and private.training_visible(t.schedule_revision_id) and t.scheduled_at>=lo and t.scheduled_at<hi
  union all
  select distinct on (old->>'id') jsonb_build_object('uid','shift-'||(old->>'id'),'start',old->>'start','end',old->>'end','title','Cancelled work shift','status','CANCELLED','sequence',(select count(*) from private.schedule_revisions z where z.week_id=w.id and z.state='Published'),'updated',current_r.released_at)
  from private.schedule_weeks w join private.schedule_revisions r on r.week_id=w.id and r.state='Published' join private.schedule_revisions current_r on current_r.id=w.published_id cross join lateral jsonb_array_elements(r.shifts) old
  where old->>'person_id'=p and (old->>'end')::timestamptz>=lo and (old->>'start')::timestamptz<hi and not exists(select 1 from jsonb_array_elements(current_r.shifts) x where x->>'id'=old->>'id' and x->>'person_id'=p)
 ) q;
 return jsonb_build_object('events',events);
end $$;
revoke all on function public.calendar_feed_data(text) from public,anon,authenticated;
grant execute on function public.calendar_feed_data(text) to service_role;
create function private.revoke_disabled_calendar() returns trigger language plpgsql security definer set search_path='' as $$begin
 if old.active and not new.active then
  if tg_table_name='staff' then delete from private.calendar_tokens where user_id in (select id from private.employee_accounts where staff_id=new.id);
  else delete from private.calendar_tokens where user_id=new.id;end if;
 end if;return new;
end $$;
create trigger disable_calendar_staff after update of active on public.staff for each row execute function private.revoke_disabled_calendar();
create trigger disable_calendar_employee after update of active on private.employee_accounts for each row execute function private.revoke_disabled_calendar();
create trigger disable_calendar_manager after update of active on public.manager_profiles for each row execute function private.revoke_disabled_calendar();
revoke all on function private.revoke_disabled_calendar() from public,anon,authenticated;
commit;
