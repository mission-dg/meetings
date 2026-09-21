import {PGlite} from '@electric-sql/pglite';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import assert from 'node:assert/strict';
test('training validates hours and eligibility, preserves meeting reminders, and limits edits to creator',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated;grant execute on function auth.uid() to authenticated;`);
 for(const name of ['001_tracker','002_admin_import','003_admin_bootstrap','004_training'])await db.exec(await readFile(new URL(`../supabase/migrations/${name}.sql`,import.meta.url),'utf8'));
 const a='00000000-0000-0000-0000-000000000001',b='00000000-0000-0000-0000-000000000002';
 await db.exec(`insert into auth.users values('${a}'),('${b}');insert into manager_profiles(id,name,is_admin) values('${a}','Admin',true),('${b}','Manager',false);`);
 async function as(id,sql,params=[]){await db.exec(`set role authenticated;set request.jwt.claim.sub='${id}';`);try{return await db.query(sql,params)}finally{await db.exec('reset role')}}
 await as(a,`insert into staff(first_name,last_name,department,is_trainer,priority) values('Trainer','One','FOH',true,false),('Trainer','Two','BOH',true,false),('New','Employee','FOH',false,true)`);
 assert.equal((await as(b,`update staff set is_trainer=true where id='New.E' returning id`)).rows.length,0);
 assert.equal((await db.query("select is_trainer from staff where id='New.E'")).rows[0].is_trainer,false);
 const insert=(trainer,date,shift=1)=>as(a,`insert into training_sessions(staff_id,trainer_id,scheduled_at,shift) values('New.E',$1,$2,$3) returning *`,[trainer,date,shift]);
 await assert.rejects(insert('New.E','2099-09-21T17:00:00Z'),/trainer|check/);
 await assert.rejects(insert('Trainer.O','2099-09-20T16:00:00Z'),/opening hours/); // Sunday 11 AM CDT
 await assert.rejects(insert('Trainer.O','2099-09-21T15:59:00Z'),/opening hours/);
 await assert.rejects(insert('Trainer.O','2099-09-22T02:00:00Z'),/opening hours/); // Monday 9 PM CDT
 await assert.rejects(insert('Trainer.O','2099-09-21T17:00:00Z',3),/check/);
 const first=(await insert('Trainer.O','2099-09-20T16:30:00Z')).rows[0];
 await insert('Trainer.T','2099-09-21T17:00:00Z',2);
 assert.equal((await as(b,'select * from training_sessions')).rows.length,2);
 assert.equal((await as(b,"update training_sessions set status='Completed' where id=$1 returning id",[first.id])).rows.length,0);
 await as(a,"update training_sessions set status='Completed' where id=$1 and version=1",[first.id]);
 assert.equal((await as(a,"update training_sessions set status='Missed' where id=$1 and version=1 returning id",[first.id])).rows.length,0);
 assert.equal((await db.query("select priority from staff where id='New.E'")).rows[0].priority,true);
 assert.equal((await db.query('select * from meetings')).rows.length,0);
 assert.equal((await db.query("select count(*)::int n from change_history where table_name='training_sessions'")).rows[0].n,3);
 await as(a,"update staff set active=false where id='Trainer.T'");
 await assert.rejects(insert('Trainer.T','2099-09-21T17:00:00Z'),/active trainer/);
 await db.exec('set role anon');await assert.rejects(db.query('select * from training_sessions'),/permission denied/);
 }finally{await db.close()}
});
