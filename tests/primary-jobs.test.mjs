import {PGlite} from '@electric-sql/pglite';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import assert from 'node:assert/strict';
test('primary job is independent of unlimited cross-training and changing it preserves qualifications',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated;grant execute on function auth.uid() to authenticated;`);
 for(const name of ['001_tracker','002_admin_import','003_admin_bootstrap','004_training','005_catering'])await db.exec(await readFile(new URL(`../supabase/migrations/${name}.sql`,import.meta.url),'utf8'));
 const a='00000000-0000-0000-0000-000000000001',b='00000000-0000-0000-0000-000000000002';
 await db.exec(`insert into auth.users values('${a}'),('${b}');insert into manager_profiles(id,name,is_admin) values('${a}','IT',true),('${b}','Manager',false);set request.jwt.claim.sub='${a}';insert into staff(first_name,last_name,department,is_trainer) values('Trainer','One','FOH',true),('New','Employee','FOH',false);`);
 for(const name of ['006_training_progress','007_staff_removal_it_roles','008_primary_jobs'])await db.exec(await readFile(new URL(`../supabase/migrations/${name}.sql`,import.meta.url),'utf8'));
 assert.equal((await db.query("select primary_job_id from staff where id='New.E'")).rows[0].primary_job_id,null);
 const jobs=(await db.query('select * from training_positions')).rows;
 const gsr=jobs.find(p=>p.name==='GSR'),line=jobs.find(p=>p.name==='Line'),expo=jobs.find(p=>p.name==='EXPO');
 async function as(id,sql,params=[]){await db.exec(`set role authenticated;set request.jwt.claim.sub='${id}';`);try{return await db.query(sql,params)}finally{await db.exec('reset role')}}
 await as(a,"update staff set primary_job_id=$1 where id='New.E'",[gsr.id]);
 assert.equal((await as(b,"update staff set primary_job_id=$1 where id='New.E' returning id",[expo.id])).rows.length,0);
 await assert.rejects(as(a,"update staff set primary_job_id=$1 where id='New.E'",[line.id]),/position group/);
 // Multiple jobs are allowed, including ones outside the employee's home group.
 for(const job of jobs){
  for(const date of ['2020-09-21','2020-09-22','2020-09-23','2020-09-24'])await as(a,"insert into training_sessions(staff_id,trainer_id,scheduled_at,shift,status,training_position_id) values('New.E','Trainer.O',$1,1,'Completed',$2)",[date+'T17:00:00Z',job.id]);
  await as(b,"insert into training_signoffs(staff_id,training_position_id) values('New.E',$1)",[job.id]);
 }
 assert.equal((await db.query("select primary_job_id from staff where id='New.E'")).rows[0].primary_job_id,gsr.id);
 await as(a,"update staff set primary_job_id=$1 where id='New.E'",[expo.id]);
 assert.equal((await db.query("select count(*)::int n from training_signoffs where staff_id='New.E' and active")).rows[0].n,6);
 assert.equal((await db.query("select count(*)::int n from training_sessions where staff_id='New.E'")).rows[0].n,24);
 await assert.rejects(as(a,'update training_positions set department=$1 where id=$2',['BOH',expo.id]),/Reassign/);
 await as(a,'update training_positions set active=false where id=$1',[expo.id]);
 await as(a,"update staff set first_name='Renamed' where id='New.E'"); // archived primary is preserved
 await assert.rejects(as(a,"insert into staff(first_name,last_name,department,primary_job_id) values('Another','Employee','FOH',$1)",[expo.id]),/active primary/);
 await as(a,"update staff set department='BOH',primary_job_id=$1 where id='New.E'",[line.id]);
 assert.equal((await db.query("select count(*)::int n from training_signoffs where staff_id='New.E'")).rows[0].n,6);
 }finally{await db.close()}
});
