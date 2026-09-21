import {PGlite} from '@electric-sql/pglite';
import {readFile} from 'node:fs/promises';
export const uid=n=>'00000000-0000-0000-0000-'+String(n).padStart(12,'0');
export const sid=n=>'10000000-0000-0000-0000-'+String(n).padStart(12,'0');
export async function fixture(seedLegacy=false){
 const db=new PGlite();await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated;grant execute on function auth.uid() to authenticated;`);
 for(const name of ['001_tracker','002_admin_import','003_admin_bootstrap','004_training','005_catering']){try{await db.exec(await readFile(new URL(`../supabase/migrations/${name}.sql`,import.meta.url),'utf8'))}catch(e){throw Error(name+': '+e.message+' '+e.where)}}
 await db.exec(`insert into auth.users values ${[1,2,3,4,5,6].map(n=>`('${uid(n)}')`).join(',')};insert into manager_profiles(id,name,is_admin) values('${uid(1)}','Admin',true),('${uid(2)}','Manager',false);set request.jwt.claim.sub='${uid(1)}';insert into staff(first_name,last_name,department,is_trainer) values('Alex','Lane','FOH',true),('Casey','Williams','FOH',false),('Jordan','Davis','BOH',false);`);
 for(const name of ['006_training_progress','007_staff_removal_it_roles','008_primary_jobs','009_scheduler','011_workspaces_requests','012_operations','014_calendar_feed','015_employee_roles']){if(seedLegacy&&name==='009_scheduler')await db.exec(`insert into meetings(id,staff_id,manager_id,type,scheduled_at,status,completed_on) values('${sid(990)}','Casey.W','${uid(1)}','Routine','2026-02-28T18:00:00Z','Completed','2026-02-28');insert into meeting_notes(meeting_id,body) values('${sid(990)}','PRIVATE manager-only evidence');insert into training_sessions(id,staff_id,trainer_id,training_position_id,shift,scheduled_at,status) select '${sid(991)}','Casey.W','Alex.L',id,1,'2026-02-27T18:00:00Z','Completed' from training_positions where name='GSR';`);try{await db.exec(await readFile(new URL(`../supabase/migrations/${name}.sql`,import.meta.url),'utf8'))}catch(e){throw Error(name+': '+e.message+' '+e.where)}}
 await db.exec(`insert into private.employee_accounts(id,staff_id,is_ca) values('${uid(3)}','Alex.L',true),('${uid(4)}','Casey.W',false),('${uid(5)}','Jordan.D',false);`);
 async function as(n,sql,params=[]){await db.exec(`set role authenticated;set request.jwt.claim.sub='${uid(n)}';`);try{return await db.query(sql,params)}catch(e){throw Error(e.message+' '+(e.where||''))}finally{await db.exec('reset role')}}
 let submission=1;async function act(n,action,payload,id=sid(submission++)){return (await as(n,'select scheduler_action($1,$2,$3) result',[action,JSON.stringify(payload),id])).rows[0].result}
 async function read(n,week='2030-09-01'){return (await as(n,'select scheduler_read($1) result',[week])).rows[0].result}
 const jobs=(await db.query('select * from training_positions')).rows;const gsr=jobs.find(j=>j.name==='GSR').id;
 const shift=(n,person='s:Casey.W',start='2030-09-02T16:00:00Z',end='2030-09-02T21:00:00Z')=>({id:sid(n+100),person_id:person,start,end,slot:1,job_id:gsr,qualification_reason:'Supervised learning'});
 return {db,as,act,read,shift,gsr};
}
