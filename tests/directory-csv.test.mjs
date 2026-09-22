import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parseDirectory,directoryCells} from '../src/directoryCsvData.ts';
import {csvText} from '../src/labor.ts';
import {fixture,uid} from './scheduler-fixture.mjs';
test('directory CSV is restricted to GM/IT, spans pages, and excludes unrelated private information',async()=>{
 const {db,as}=await fixture();try{
 await assert.rejects(as(4,'select directory_csv_export()'),/GM or IT/);
 await assert.rejects(as(3,'select directory_csv_export()'),/GM or IT/);
 await assert.rejects(as(2,'select directory_csv_export()'),/GM or IT/);
 await db.query('update manager_profiles set is_gm=true where id=$1',[uid(2)]);
 await db.exec("insert into private.person_contacts(person_id,phone,email,emergency_name,emergency_phone) values('s:Casey.W','555-0100','casey@example.test','PRIVATE EMERGENCY','555-0199')");
 await db.exec("insert into staff(first_name,last_name,department) select 'Example'||n,'Person','FOH' from generate_series(1,55) n");
 const get=async n=>(await as(n,'select directory_csv_export() r')).rows[0].r;
 const gm=await get(2),it=await get(1);assert.equal(gm.length,58);assert.deepEqual(gm,it);
 assert.ok(!JSON.stringify(gm).includes('555-0100'));
 assert.match(gm.find(p=>p.staff_id==='Casey.W').revision,/^[a-f0-9]{32}$/);
 assert.ok(!JSON.stringify(gm).includes('PRIVATE EMERGENCY'));assert.ok(!JSON.stringify(gm).includes('hourly_rate'));
 }finally{await db.close()}
});

test('directory CSV edits are atomic, versioned, idempotent and preserve identity and permissions',async()=>{
 const {db,as,gsr}=await fixture();try{
 await db.query('update manager_profiles set is_gm=true where id=$1',[uid(2)]);
 const exp=async()=>(await as(2,'select directory_csv_export() r')).rows[0].r;
 const initial=await exp();let rows=initial.filter(r=>r.staff_id==='Casey.W');rows[0]={...rows[0],first_name:'Casey Updated',primary_job:'GSR',earned_jobs:['gsr','Prep','GSR'],trainer_roles:['GSR','Prep']};
 const review=async r=>(await as(2,'select directory_csv_review($1) r',[r])).rows[0].r;
 await assert.rejects(as(1,'select directory_csv_review($1)',[[{...rows[0],earned_jobs:['Typo']}]]),/Unknown/);
 const plan=await review(rows);assert.equal(plan.rows[0].changed,true);assert.deepEqual(plan.rows[0].after.qualifications_to_add,['GSR','Prep']);
 const batch=crypto.randomUUID();const apply=async()=>(await as(2,'select directory_csv_apply($1,$2,$3) r',[rows,plan.fingerprint,batch])).rows[0].r;
 assert.equal((await apply()).updated,1);assert.equal((await apply()).updated,1);
 const staff=(await db.query("select * from staff where id='Casey.W'")).rows[0];assert.equal(staff.first_name,'Casey Updated');assert.equal(staff.primary_job_id,gsr);assert.equal(staff.trainer_job_ids.length,2);
 assert.equal((await db.query("select count(*) n from training_signoffs where staff_id='Casey.W' and active")).rows[0].n,2);
 assert.equal((await db.query('select count(*) n from training_sessions')).rows[0].n,0);
 assert.equal((await db.query("select staff_id from private.employee_accounts where id=$1",[uid(4)])).rows[0].staff_id,'Casey.W');
 await assert.rejects(review(initial.filter(r=>r.staff_id==='Casey.W')),/changed/);
 const fresh=await exp();const changes=fresh.filter(r=>['Casey.W','Jordan.D'].includes(r.staff_id)).map(r=>({...r,last_name:'Changed'}));let p=await review(changes);
 await db.query("update staff set priority=true where id='Jordan.D'");
 await assert.rejects(as(2,'select directory_csv_apply($1,$2,$3)',[changes,p.fingerprint,crypto.randomUUID()]),/changed/);
 assert.equal((await db.query("select last_name from staff where id='Casey.W'")).rows[0].last_name,'Williams');
 await assert.rejects(as(4,'select directory_csv_apply($1,$2,$3)',[rows,plan.fingerprint,crypto.randomUUID()]),/GM or IT/);
 const current=(await exp()).find(r=>r.staff_id==='Casey.W');const noRoles=[{...current,earned_jobs:[],trainer_roles:[]}];p=await review(noRoles);await as(2,'select directory_csv_apply($1,$2,$3)',[noRoles,p.fingerprint,crypto.randomUUID()]);
 assert.equal((await db.query("select is_trainer from staff where id='Casey.W'")).rows[0].is_trainer,false);
 assert.equal((await db.query("select count(*) n from training_signoffs where staff_id='Casey.W' and active")).rows[0].n,2);
 }finally{await db.close()}
});
test('directory CSV quoted role lists and formula-safe text round-trip',()=>{
 const row={staff_id:'Test.A',revision:'abc',first_name:'=Example',last_name:"'Literal",primary_job:'GSR',earned_jobs:['GSR','EXPO'],trainer_roles:['GSR','EXPO']};
 assert.deepEqual(parseDirectory(csvText(directoryCells([row]))),[row]);
 assert.throws(()=>parseDirectory(csvText(directoryCells([row,row]))),/duplicate/);
});
