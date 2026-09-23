begin;
-- Stable defaults are catalog entries, not privileges or qualifications.
create table private.schedule_color_defaults(key text primary key,preset text not null);
create table private.appearance_preferences(user_id uuid primary key references auth.users(id) on delete cascade,version int not null default 1,mode text not null default 'light',palette text not null default 'classic',overrides jsonb not null default '{}');
create table private.appearance_submissions(user_id uuid not null references auth.users(id) on delete cascade,submission uuid not null,payload jsonb not null,result jsonb not null,primary key(user_id,submission));
alter table private.schedule_color_defaults enable row level security;
alter table private.appearance_preferences enable row level security;
alter table private.appearance_submissions enable row level security;
revoke all on private.schedule_color_defaults,private.appearance_preferences,private.appearance_submissions from public,anon,authenticated;
create function private.schedule_color_presets() returns text[] language sql immutable set search_path='' as $$select array['ocean','forest','violet','rust','teal','rose','indigo','olive','copper','berry','slate','jade','cranberry','azure','plum','ochre','pine','clay','periwinkle','moss','magenta','denim','cinnamon','grape']::text[]$$;
create function private.ensure_schedule_color(p_key text) returns void language plpgsql security definer set search_path='' as $$
declare color text;
begin
 perform pg_advisory_xact_lock(61902037);
 if exists(select 1 from private.schedule_color_defaults where key=p_key) then return;end if;
 select p into color from unnest(private.schedule_color_presets()) with ordinality a(p,n) where not exists(select 1 from private.schedule_color_defaults d where d.preset=p) order by n limit 1;
 if color is null then select p into color from unnest(private.schedule_color_presets()) with ordinality a(p,n) order by (select count(*) from private.schedule_color_defaults d where d.preset=p),n limit 1;end if;
 insert into private.schedule_color_defaults values(p_key,color);
end $$;
insert into private.schedule_color_defaults values('type:opening_office','slate'),('type:closing_office','violet'),('type:training','rose'),('type:staff_meeting','rust'),('type:shl','ochre');
-- Reserve distinctive defaults for common jobs before assigning the remainder.
insert into private.schedule_color_defaults(key,preset)
select 'job:'||id::text,case name when 'GSR' then 'ocean' when 'Line' then 'jade' when 'EXPO' then 'azure' when 'Prep' then 'indigo' when 'DRL' then 'olive' when 'Catering' then 'berry' when 'CA' then 'copper' when 'TA' then 'cranberry' when 'hSHL' then 'forest' when 'sSHL' then 'plum' when 'GM' then 'teal' end
from public.training_positions where name in ('GSR','Line','EXPO','Prep','DRL','Catering','CA','TA','hSHL','sSHL','GM');
do $$declare k text;begin for k in select 'job:'||id::text from public.training_positions order by name,id loop perform private.ensure_schedule_color(k);end loop;end $$;
create function private.new_job_schedule_color() returns trigger language plpgsql security definer set search_path='' as $$begin perform private.ensure_schedule_color('job:'||new.id::text);return new;end $$;
create trigger job_schedule_color after insert on public.training_positions for each row execute function private.new_job_schedule_color();
create function public.appearance_read() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p private.appearance_preferences;begin
 if not private.scheduler_member() then raise exception 'Active account required';end if;
 select * into p from private.appearance_preferences where user_id=auth.uid();
 return jsonb_build_object('version',coalesce(p.version,0),'mode',coalesce(p.mode,'light'),'palette',coalesce(p.palette,'classic'),'overrides',coalesce(p.overrides,'{}'),'defaults',(select coalesce(jsonb_object_agg(key,preset),'{}') from private.schedule_color_defaults));
end $$;
create function public.appearance_save(p_version int,p_mode text,p_palette text,p_overrides jsonb,p_submission uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare previous private.appearance_preferences;prior private.appearance_submissions;payload jsonb;result jsonb;
begin
 if not private.scheduler_member() then raise exception 'Active account required';end if;
 if p_submission is null then raise exception 'Submission required';end if;
 perform pg_advisory_xact_lock(hashtextextended('appearance:'||auth.uid()::text,0));
 payload:=jsonb_build_object('version',p_version,'mode',p_mode,'palette',p_palette,'overrides',p_overrides);
 select * into prior from private.appearance_submissions where user_id=auth.uid() and submission=p_submission;
 if found then if prior.payload is distinct from payload then raise exception 'Submission changed';end if;return prior.result;end if;
 if p_mode is null or p_mode not in ('light','dark','system') or p_palette is null or p_palette not in ('classic','vivid','soft') or jsonb_typeof(p_overrides) is distinct from 'object' or length(p_overrides::text)>50000 then raise exception 'Invalid appearance settings';end if;
 if exists(select 1 from jsonb_each_text(p_overrides) e where not exists(select 1 from private.schedule_color_defaults d where d.key=e.key) or e.value is null or not(e.value=any(private.schedule_color_presets()))) then raise exception 'Choose a valid job and preset color';end if;
 select * into previous from private.appearance_preferences where user_id=auth.uid();
 if p_version is distinct from coalesce(previous.version,0) then raise exception 'Your appearance changed on another device. Reload saved appearance before saving';end if;
 insert into private.appearance_preferences values(auth.uid(),1,p_mode,p_palette,p_overrides) on conflict(user_id) do update set version=appearance_preferences.version+1,mode=excluded.mode,palette=excluded.palette,overrides=excluded.overrides;
 result:=public.appearance_read();
 insert into private.appearance_submissions values(auth.uid(),p_submission,payload,result);
 perform private.schedule_audit('personal_appearance',auth.uid()::text,to_jsonb(previous)-'user_id',result-'defaults');
 return result;
end $$;
-- Only annotate shifts already present in the permission-filtered response.
-- No meeting titles, attendance lists, or notes are added to this projection.
alter function public.workspace_read(date,text) rename to workspace_read_before_colors;
revoke all on function public.workspace_read_before_colors(date,text) from public,anon,authenticated;
create function public.workspace_read(p_week date,p_view text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;items jsonb;links jsonb;
begin
 r:=public.workspace_read_before_colors(p_week,p_view);
 select coalesce(jsonb_agg(s),'[]') into items from jsonb_array_elements(r->'published') w cross join lateral jsonb_array_elements(w->'shifts') s;
 items:=items||coalesce(nullif(r#>'{week,draft,shifts}','null'::jsonb),'[]');
 select coalesce(jsonb_object_agg(s->>'id',m.id::text),'{}') into links from jsonb_array_elements(items) s join private.staff_meetings m on exists(select 1 from jsonb_array_elements(m.generated) g where g->>'id'=s->>'id' and g->>'assignment_type'='training') where s->>'assignment_type'='training';
 return r||jsonb_build_object('schedule_meeting_shifts',links);
end $$;
revoke all on function private.schedule_color_presets(),private.ensure_schedule_color(text),private.new_job_schedule_color() from public,anon,authenticated;
revoke all on function public.appearance_read(),public.appearance_save(int,text,text,jsonb,uuid),public.workspace_read(date,text) from public,anon;
grant execute on function public.appearance_read(),public.appearance_save(int,text,text,jsonb,uuid),public.workspace_read(date,text) to authenticated;
notify pgrst,'reload schema';
commit;
