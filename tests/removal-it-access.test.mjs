import {PGlite} from '@electric-sql/pglite';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import assert from 'node:assert/strict';
test('typed removal preserves history; only active IT/GM can change IT access without losing the last admin',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated;grant execute on function auth.uid() to authenticated;`);
 for(const name of ['001_tracker','002_admin_import','003_admin_bootstrap','004_training','005_catering','006_training_progress','007_staff_removal_it_roles'])await db.exec(await readFile(new URL(`../supabase/migrations/${name}.sql`,import.meta.url),'utf8'));
 const a='00000000-0000-0000-0000-000000000001',g='00000000-0000-0000-0000-000000000002',m='00000000-0000-0000-0000-000000000003';
 await db.exec(`insert into auth.users values('${a}'),('${g}'),('${m}');insert into manager_profiles(id,name,is_admin,is_gm) values('${a}','IT',true,false),('${g}','GM',false,true),('${m}','SHL',false,false);`);
 async function as(id,sql,params=[]){await db.exec(`set role authenticated;set request.jwt.claim.sub='${id}';`);try{return await db.query(sql,params)}finally{await db.exec('reset role')}}
 await as(a,"insert into staff(first_name,last_name,department) values('Test','Employee','FOH')");
 await as(a,"select schedule_meeting('Test.E',$1,'Routine','2099-09-21T17:00:00Z',null)",[a]);
 const remove=(caller,phrase,confirm)=>as(caller,"select admin_remove_staff('Test.E',$1,$2)",[phrase,confirm]);
 await assert.rejects(remove(a,'Remove Test Employee','confirm'),/exact/);
 await assert.rejects(remove(a,'Remove Test Employee ', 'Confirm'),/exact/);
 await assert.rejects(remove(a,'Remove Someone Else','Confirm'),/exact/);
 await assert.rejects(remove(a,null,'Confirm'),/exact/);
 await assert.rejects(remove(g,'Remove Test Employee','Confirm'),/IT Admin/);
 await assert.rejects(remove(m,'Remove Test Employee','Confirm'),/IT Admin/);
 assert.equal((await db.query("select active from staff where id='Test.E'")).rows[0].active,true);
 await remove(a,'Remove Test Employee','Confirm');
 assert.equal((await db.query("select active from staff where id='Test.E'")).rows[0].active,false);
 assert.equal((await db.query("select status from meetings where staff_id='Test.E'")).rows[0].status,'Scheduled');
 await as(a,"update staff set active=true,first_name='Renamed' where id='Test.E'");
 await assert.rejects(remove(a,'Remove Test Employee','Confirm'),/name changed/);
 const role=(caller,target,admin,version)=>as(caller,'select set_it_access($1,$2,$3)',[target,admin,version]);
 await assert.rejects(role(m,m,true,1),/IT Admin or GM/);
 await assert.rejects(role(g,a,false,1),/at least one/);
 await role(g,m,true,1);
 assert.equal((await db.query('select is_admin from manager_profiles where id=$1',[m])).rows[0].is_admin,true);
 await assert.rejects(role(g,m,false,1),/changed/);
 await role(a,a,false,1); // self-demotion is safe with another active IT account
 await assert.rejects(role(a,a,true,2),/IT Admin or GM/);
 await role(g,a,true,2);
 await role(g,m,false,2);
 await assert.rejects(as(g,"select admin_update_manager($1,'Unauthorized',true,false,false,3)",[m]),/IT Admin access/);
 await db.exec(`update manager_profiles set active=false where id='${m}';`);
 await assert.rejects(role(g,m,true,3),/Activate/);
 await role(g,g,true,1); // GM may grant themselves IT for testing
 await role(g,g,false,2);
 assert.equal((await db.query('select is_gm from manager_profiles where id=$1',[g])).rows[0].is_gm,true);
 assert.ok((await db.query("select * from change_history where table_name='manager_profiles'")).rows.length>3);
 await db.exec('set role anon');await assert.rejects(db.query('select set_it_access($1,true,1)',[m]),/permission denied/);
 }finally{await db.close()}
});
