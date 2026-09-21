import {PGlite} from '@electric-sql/pglite';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import assert from 'node:assert/strict';
test('training job migration preserves legacy sessions, gates sign-off, and audits creator-only confirmations',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated;grant execute on function auth.uid() to authenticated;`);
 for(const name of ['001_tracker','002_admin_import','003_admin_bootstrap','004_training','005_catering'])await db.exec(await readFile(new URL(`../supabase/migrations/${name}.sql`,import.meta.url),'utf8'));
 const a='00000000-0000-0000-0000-000000000001',b='00000000-0000-0000-0000-000000000002';
 await db.exec(`insert into auth.users values('${a}'),('${b}');insert into manager_profiles(id,name,is_admin) values('${a}','Admin',true),('${b}','Manager',false);set request.jwt.claim.sub='${a}';insert into staff(first_name,last_name,department,is_trainer) values('Trainer','One','FOH',true),('New','Employee','BOH',false);insert into training_sessions(staff_id,trainer_id,scheduled_at,shift,status) values('New.E','Trainer.O','2020-09-21T17:00:00Z',1,'Completed');`);
 await db.exec(await readFile(new URL('../supabase/migrations/006_training_progress.sql',import.meta.url),'utf8'));
 assert.equal((await db.query('select * from training_positions')).rows.length,6);
 const job=(await db.query("select id from training_positions where name='GSR'")).rows[0].id;
 const legacy=(await db.query('select * from training_sessions')).rows[0];assert.equal(legacy.training_position_id,null);
 async function as(id,sql,params=[]){await db.exec(`set role authenticated;set request.jwt.claim.sub='${id}';`);try{return await db.query(sql,params)}finally{await db.exec('reset role')}}
 await assert.rejects(as(b,"insert into training_positions(name,department) values('Unauthorized','FOH')"),/policy/);
 await as(a,'update training_sessions set training_position_id=$1 where id=$2',[job,legacy.id]);
 const sign=()=>as(b,"insert into training_signoffs(staff_id,training_position_id) values('New.E',$1) returning *",[job]);
 await assert.rejects(sign(),/target number/);
 await as(a,"insert into training_sessions(staff_id,trainer_id,scheduled_at,shift,status,training_position_id) values('New.E','Trainer.O','2020-09-21T18:00:00Z',1,'Completed',$1)",[job]);
 await assert.rejects(sign(),/target number/); // duplicate same shift does not count
 for(const date of ['2020-09-22','2020-09-23','2020-09-24'])await as(a,"insert into training_sessions(staff_id,trainer_id,scheduled_at,shift,status,training_position_id) values('New.E','Trainer.O',$1,1,'Completed',$2)",[date+'T17:00:00Z',job]);
 const signed=(await sign()).rows[0];assert.equal(signed.created_by,b);
 assert.equal((await as(a,'select * from training_signoffs')).rows.length,1);
 assert.equal((await as(a,'update training_signoffs set active=false where id=$1 returning id',[signed.id])).rows.length,0);
 await assert.rejects(sign(),/unique/);
 await as(b,'update training_signoffs set active=false where id=$1 and version=1',[signed.id]);
 assert.equal((await as(b,'update training_signoffs set active=true where id=$1 and version=1 returning id',[signed.id])).rows.length,0);
 await as(a,'update training_positions set target_shifts=6 where id=$1',[job]);
 await assert.rejects(sign(),/target number/);
 await assert.rejects(as(a,"insert into training_sessions(staff_id,trainer_id,scheduled_at,shift) values('New.E','Trainer.O','2099-09-21T17:00:00Z',1)"),/training job/);
 await assert.rejects(as(a,"insert into training_sessions(staff_id,trainer_id,scheduled_at,shift,status,training_position_id) values('New.E','Trainer.O','2099-09-21T17:00:00Z',1,'Completed',$1)",[job]),/future/);
 assert.equal((await db.query("select count(*)::int n from change_history where table_name='training_signoffs'")).rows[0].n,2);
 await db.exec('set role anon');await assert.rejects(db.query('select * from training_signoffs'),/permission denied/);
 }finally{await db.close()}
});
