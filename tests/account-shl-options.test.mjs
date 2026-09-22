import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture,uid} from './scheduler-fixture.mjs';
test('IT account selections synchronize SHL eligibility, management access and safe retries',async()=>{
 const f=await fixture();try{
 await f.db.exec(await readFile(new URL('../supabase/migrations/031_account_shl_options.sql',import.meta.url),'utf8'));
 await f.db.query('update staff set primary_job_id=$1 where id=$2',[f.gsr,'Casey.W']);
 async function args(role){const a=(await f.db.query('select a.version,coalesce(m.version,0) mv from private.employee_accounts a left join manager_profiles m on m.id=a.id where a.id=$1',[uid(4)])).rows[0];return [uid(4),role,a.version,a.mv,crypto.randomUUID()]}
 const call=(n,a)=>f.as(n,'select set_employee_role($1,$2,$3,$4,$5)',a);
 const hourly=await args('hSHL');await assert.rejects(call(2,hourly),/IT Admin/);await call(1,hourly);await call(1,hourly);
 assert.equal((await f.read(4)).self.is_manager,false);
 assert.equal((await f.db.query("select private.staff_shl_code('Casey.W') code")).rows[0].code,'hSHL');
 await call(1,await args('sSHL'));assert.equal((await f.read(4)).self.is_manager,true);
 assert.equal((await f.db.query("select private.person_employment('s:Casey.W') kind")).rows[0].kind,'Salaried');
 await assert.rejects(call(1,hourly.slice(0,4).concat(crypto.randomUUID())),/changed/);
 await call(1,await args('hSHL'));assert.equal((await f.read(4)).self.is_manager,false);
 await call(1,await args('employee'));assert.equal((await f.db.query("select private.staff_shl_code('Casey.W') code")).rows[0].code,null);
 assert.equal((await f.db.query("select primary_job_id from staff where id='Casey.W'")).rows[0].primary_job_id,f.gsr);
 }finally{await f.db.close()}
});
