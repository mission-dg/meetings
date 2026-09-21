import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture,uid,sid} from './scheduler-fixture.mjs';
async function setup(){const f=await fixture();await f.db.exec('alter table auth.users add column email text;alter table auth.users add column encrypted_password text;');await f.db.exec(await readFile(new URL('../supabase/migrations/016_username_accounts.sql',import.meta.url),'utf8'));await f.as(1,"insert into staff(first_name,last_name,department) values('New','Employee','FOH'),('Other','Employee','BOH')");return f}
test('username creation: IT and GM only, case-insensitive uniqueness, replay guard and existing-account protection',async()=>{
 const {db,as}=await setup();try{
 const reserve=(n,staff,user,submission=crypto.randomUUID())=>as(n,'select reserve_username_account($1,$2,$3) r',[staff,user,submission]);
 for(const n of [2,3,4])await assert.rejects(reserve(n,'New.E','new.employee'),/IT or GM/);
 await db.exec(`update manager_profiles set is_gm=true where id='${uid(2)}'`);
 const request=sid(901);const r=(await reserve(2,'New.E',' New.Employee ',request)).rows[0].r;assert.equal(r.username,'new.employee');
 await assert.rejects(reserve(1,'Other.E','NEW.EMPLOYEE'),/taken/);
 await assert.rejects(reserve(1,'New.E','new.employee',request),/already processed/);
 await assert.rejects(reserve(1,'New.E','changed.name'),/existing username/);
 await assert.rejects(reserve(1,'Casey.W','casey'),/already has an account/);
 for(const name of ['ab','bad email','user@example.com','bad/name',null])await assert.rejects(reserve(1,'Other.E',name),/3–32/);
 await db.exec(`set request.jwt.claim.sub='${r.user_id}';set role authenticated;`);
 await assert.rejects(db.query('select workspace_session()'),/access/);
 await assert.rejects(db.query('select username_account_list()'),/IT or GM/);
 await assert.rejects(db.query('select temporary_hash from private.username_accounts'),/permission denied/);
 await assert.rejects(db.query('select finish_username_account($1)',[request]),/permission denied/);
 }finally{await db.close()}
});
test('temporary password: no workspace access until real password change; preserves identity; activation is idempotent',async()=>{
 const {db,as}=await setup();try{
 const request=sid(902),r=(await as(1,'select reserve_username_account($1,$2,$3) r',['New.E','new.employee',request])).rows[0].r;
 await db.query('insert into auth.users(id,email,encrypted_password) values($1,$2,$3)',[r.user_id,r.email,'temporary-hash']);
 await db.query('select finish_username_account($1)',[request]);
 await db.exec(`set request.jwt.claim.sub='${r.user_id}';set role authenticated;`);
 assert.equal((await db.query('select username_account_status() r')).rows[0].r.required,true);
 await assert.rejects(db.query('select activate_username_account()'),/Set your own password/);
 await assert.rejects(db.query('select scheduler_read($1)',['2030-09-01']),/access/);
 assert.equal((await db.query('select * from staff')).rows.length,0);
 await db.exec('reset role');await db.query('update auth.users set encrypted_password=$1 where id=$2',['personal-hash',r.user_id]);
 await db.exec('set role authenticated');await db.query('select activate_username_account()');await db.query('select activate_username_account()');
 assert.deepEqual((await db.query('select workspace_session() r')).rows[0].r.views,['employee']);
 assert.equal((await db.query('select username_account_status() r')).rows[0].r.required,false);
 await db.exec('reset role');assert.equal((await db.query('select staff_id from private.employee_accounts where id=$1',[r.user_id])).rows[0].staff_id,'New.E');assert.equal((await db.query('select temporary_hash from private.username_accounts where user_id=$1',[r.user_id])).rows[0].temporary_hash,null);
 await assert.rejects(as(1,'select reserve_username_account($1,$2,$3)',['New.E','new.employee',sid(903)]),/already has an account/);
 }finally{await db.close()}
});
test('temporary expiry, deactivation and reissue fail closed; email invitation cannot race username reservation',async()=>{
 const {db,as}=await setup();try{
 const request=sid(904),r=(await as(1,'select reserve_username_account($1,$2,$3) r',['New.E','new.employee',request])).rows[0].r;
 await db.query('insert into auth.users(id,email,encrypted_password) values($1,$2,$3)',[r.user_id,r.email,'temp']);await db.query('select finish_username_account($1)',[request]);
 await db.query("update private.username_accounts set expires_at=now()-interval '1 minute' where user_id=$1",[r.user_id]);await db.query("update auth.users set encrypted_password='new' where id=$1",[r.user_id]);
 await db.exec(`set request.jwt.claim.sub='${r.user_id}';set role authenticated;`);await assert.rejects(db.query('select activate_username_account()'),/new temporary password/);await db.exec('reset role');
 const next=sid(905);assert.equal((await as(1,'select reserve_username_account($1,$2,$3) r',['New.E','new.employee',next])).rows[0].r.user_id,r.user_id);
 await assert.rejects(as(1,'select reserve_username_account($1,$2,$3)',['New.E','new.employee',sid(906)]),/in progress/);
 await assert.rejects(db.query('select finish_username_account($1)',[request]));
 await db.query('select finish_username_account($1)',[next]);await db.exec("update staff set active=false where id='New.E'");
 await db.query("update auth.users set encrypted_password='newer' where id=$1",[r.user_id]);await db.exec(`set request.jwt.claim.sub='${r.user_id}';set role authenticated;`);await assert.rejects(db.query('select activate_username_account()'),/Access changed/);await db.exec('reset role');
 await assert.rejects(db.query('insert into private.employee_invitations(id,actor,staff_id,email) values($1,$2,$3,$4)',[sid(907),uid(1),'New.E','some@example.com']),/username account/);
 }finally{await db.close()}
});
