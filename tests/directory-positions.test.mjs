import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture} from './scheduler-fixture.mjs';
test('directory preserves hourly leader primary jobs and salaried labels in both workspaces',async()=>{
 const f=await fixture();try{
 await f.db.exec(await readFile(new URL('../supabase/migrations/030_directory_positions.sql',import.meta.url),'utf8'));
 await f.db.query('update staff set primary_job_id=$1 where id=$2',[f.gsr,'Casey.W']);
 const jobs=(await f.db.query("select id,name from training_positions where name in ('hSHL','sSHL')")).rows;
 async function qualify(name){await f.as(1,'select set_job_qualification($1,$2,$3,$4,$5,$6)',['Casey.W',jobs.find(j=>j.name===name).id,'override','Previously trained',0,crypto.randomUUID()])}
 await qualify('hSHL');
 for(const [user,view] of [[1,'manager'],[4,'employee']]){const r=(await f.as(user,"select operations_read('directory',$1) r",[view])).rows[0].r;const c=r.items.find(x=>x.person_id==='s:Casey.W');assert.equal(c.group,'hSHL');assert.equal(c.job,'GSR');assert.equal(c.emergency_name,null)}
 await f.as(1,'select set_job_qualification($1,$2,$3,$4,$5,$6)',['Casey.W',jobs.find(j=>j.name==='hSHL').id,'revoke','Changing classification',1,crypto.randomUUID()]);
 await qualify('sSHL');
 const r=(await f.as(1,"select operations_read('directory','manager') r")).rows[0].r;const c=r.items.find(x=>x.person_id==='s:Casey.W');assert.equal(c.group,'sSHL');assert.equal(c.job,'sSHL');
 assert.equal((await f.db.query("select primary_job_id from staff where id='Casey.W'")).rows[0].primary_job_id,f.gsr);
 }finally{await f.db.close()}
});
