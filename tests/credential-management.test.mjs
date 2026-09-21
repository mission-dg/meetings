import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture,uid} from './scheduler-fixture.mjs';
async function setup(){
 const f=await fixture();const {db}=f;
 await db.exec('alter table auth.users add column email text;alter table auth.users add column encrypted_password text;create table auth.sessions(id uuid primary key,user_id uuid,created_at timestamptz default clock_timestamp());');
 for(const file of ['016_username_accounts','017_account_credentials'])await db.exec(await readFile(new URL('../supabase/migrations/'+file+'.sql',import.meta.url),'utf8'));
 await f.as(1,"insert into staff(first_name,last_name,department) values('New','Person','FOH'),('Second','Person','BOH')");
 const prepare=async(actor,staff,username,role='employee',target=null,version=0,submission=crypto.randomUUID())=>(await f.as(actor,'select prepare_username_login($1,$2,$3,$4,$5,$6) r',[staff,username,role,target,version,submission])).rows[0].r;
 const provision=async(r)=>{await db.query('insert into auth.users(id,email,encrypted_password) values($1,$2,$3) on conflict(id) do update set email=excluded.email,encrypted_password=excluded.encrypted_password',[r.user_id,r.email,crypto.randomUUID()]);await db.query('select finish_username_account(submission) from private.username_accounts where user_id=$1',[r.user_id]);};
 const login=async(r)=>{const id=crypto.randomUUID();await db.query('insert into auth.sessions(id,user_id) values($1,$2)',[id,r.user_id]);return id};
 const call=async(user,session,sql,args=[])=>{await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claims',$2,false)",[user,JSON.stringify({session_id:session})]);await db.exec('set role authenticated');try{return await db.query(sql,args)}finally{await db.exec('reset role')}};
 const activate=async(r,session)=>{await db.query('update auth.users set encrypted_password=$1 where id=$2',[crypto.randomUUID(),r.user_id]);await call(r.user_id,session,'select activate_username_account()')};
 const account=async(r)=>(await db.query('select * from private.username_accounts where user_id=$1',[r.user_id])).rows[0];
 return {...f,prepare,provision,login,call,activate,account};
}
test('GM/IT create Employee or Manager without email; temporary manager login cannot read manager records',async()=>{
 const {db,prepare,provision,login,call,activate}=await setup();try{
 await assert.rejects(prepare(2,'New.P','new.person','manager'),/IT or GM/);
 await db.exec(`update manager_profiles set is_gm=true where id='${uid(2)}'`);
 await assert.rejects(prepare(2,'New.P','new.person','it'),/Employee or Manager/);
 const r=await prepare(2,'New.P','NEW.Person','manager');await provision(r);const session=await login(r);
 await assert.rejects(call(r.user_id,session,'select workspace_session()'),/access/);
 assert.equal((await call(r.user_id,session,'select * from meetings')).rows.length,0);
 await assert.rejects(call(r.user_id,session,'select activate_username_account()'),/Set your own password/);
 await activate(r,session);assert.deepEqual((await call(r.user_id,session,'select workspace_session() r')).rows[0].r.views,['manager','employee']);
 assert.equal((await db.query('select linked_staff_id,is_admin,is_gm from manager_profiles where id=$1',[r.user_id])).rows[0].linked_staff_id,'New.P');
 assert.equal((await db.query('select is_admin from manager_profiles where id=$1',[r.user_id])).rows[0].is_admin,false);
 const employee=await prepare(1,'Second.P','second.person');await provision(employee);const employeeSession=await login(employee);await activate(employee,employeeSession);
 assert.deepEqual((await call(employee.user_id,employeeSession,'select workspace_session() r')).rows[0].r.views,['employee']);
 }finally{await db.close()}
});
test('GM/IT reset activated credentials and rename without changing roles; old sessions and names cannot be reused',async()=>{
 const {db,prepare,provision,login,call,activate,account,as}=await setup();try{
 const r=await prepare(1,'New.P','new.person','manager');await provision(r);const oldSession=await login(r);await activate(r,oldSession);
 const before=(await db.query('select * from manager_profiles where id=$1',[r.user_id])).rows[0];let a=await account(r);
 await assert.rejects(prepare(1,'New.P','renamed.person','employee',r.user_id,a.version-1),/changed/);
 await db.exec(`update manager_profiles set is_gm=true where id='${uid(2)}'`);
 await db.query("insert into private.calendar_tokens(user_id,token_hash) values($1,'test')",[r.user_id]);
 const reset=await prepare(2,'ignored','renamed.person','employee',r.user_id,a.version);
 assert.equal((await db.query('select * from private.calendar_tokens where user_id=$1',[r.user_id])).rows.length,0);
 await assert.rejects(call(r.user_id,oldSession,'select workspace_session()'),/access/);
 assert.equal((await call(r.user_id,oldSession,'select * from meetings')).rows.length,0);
 await assert.rejects(prepare(1,'Second.P','new.person'),/reserved/);
 a=await account(r);await assert.rejects(prepare(2,'New.P','renamed.person','manager',r.user_id,a.version),/in progress/);
 await provision(reset);await db.query('delete from auth.sessions where user_id=$1',[r.user_id]);
 await assert.rejects(call(r.user_id,oldSession,'select activate_username_account()'),/Sign out/);
 const fresh=await login(r);await activate(reset,fresh);
 assert.deepEqual((await db.query('select * from manager_profiles where id=$1',[r.user_id])).rows[0],before);
 assert.deepEqual((await call(r.user_id,fresh,'select workspace_session() r')).rows[0].r.views,['manager','employee']);
 await assert.rejects(call(r.user_id,oldSession,'select workspace_session()'),/access/);
 assert.equal((await db.query('select count(*) n from private.employee_accounts where staff_id=$1',['New.P'])).rows[0].n,1);
 await as(1,"update staff set active=false where id='New.P'");a=await account(r);await assert.rejects(prepare(2,'New.P','renamed.person','employee',r.user_id,a.version),/Reactivate/);
 }finally{await db.close()}
});
test('account editing denies self reset, duplicate submissions, reused usernames and activation from expired sessions',async()=>{
 const {db,prepare,provision,login,call,activate,account}=await setup();try{
 const submission=crypto.randomUUID();const r=await prepare(1,'New.P','new.person','manager',null,0,submission);await provision(r);const session=await login(r);await activate(r,session);
 await assert.rejects(prepare(1,'Second.P','second.person','employee',null,0,submission),/already processed/);
 await db.query('update manager_profiles set is_admin=true where id=$1',[r.user_id]);const a=await account(r);
 await assert.rejects(call(r.user_id,session,'select prepare_username_login($1,$2,$3,$4,$5,$6)',['New.P','self','employee',r.user_id,a.version,crypto.randomUUID()]),/own login/);
 await db.query('delete from auth.sessions where id=$1',[session]);await assert.rejects(call(r.user_id,session,'select username_account_list()'),/IT or GM/);
 await assert.rejects(call(r.user_id,session,'select prepare_username_login($1,$2,$3,$4,$5,$6)',['Second.P','second','employee',null,0,crypto.randomUUID()]),/IT or GM/);
 }finally{await db.close()}
});
