import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,uid} from './scheduler-fixture.mjs';

test('SHL codes control office eligibility, salary classification and account access independently of primary job',async()=>{
 const {db,as,act,read,shift}=await fixture();try{
 const jobs=(await db.query("select id,name from training_positions where department='SHL'")).rows;
 const h=jobs.find(j=>j.name==='hSHL').id,s=jobs.find(j=>j.name==='sSHL').id;
 const qualify=(person,job,actor=1)=>as(actor,'select set_job_qualification($1,$2,\'override\',\'Experienced leader\',0,$3)',[person,job,crypto.randomUUID()]);
 await assert.rejects(qualify('Casey.W',h,2),/GM or IT/);
 await qualify('Casey.W',h);
 let data=await read(4);assert.equal(data.self.is_manager,false);assert.equal(data.people.find(p=>p.id==='s:Casey.W').employment_type,'Hourly');
 await assert.rejects(act(4,'draft',{week:'2030-09-01',shifts:[]}),/Manager/);
 await assert.rejects(as(1,'select set_employee_role($1,\'manager\',1,0,$2)',[uid(4),crypto.randomUUID()]),/hSHL/);
 await qualify('Jordan.D',s);
 data=await read(5);assert.equal(data.self.is_manager,true);assert.equal(data.people.find(p=>p.id==='s:Jordan.D').employment_type,'Salaried');
 assert.equal((await db.query("select primary_job_id from staff where id='Jordan.D'")).rows[0].primary_job_id,null);
 // The office validator accepts both codes without a regular job.
 await act(5,'draft',{week:'2030-09-01'});const d=(await read(5)).week.draft;
 await act(5,'save',{id:d.id,version:d.version,shifts:[{...shift(1),job_id:null,assignment_type:'opening_office'},{...shift(2,'s:Jordan.D'),job_id:null,assignment_type:'closing_office'}]});
 await assert.rejects(qualify('Casey.W',s),/one SHL code/);
 const f=(await db.query("select * from training_signoffs where staff_id='Jordan.D' and training_position_id=$1 and active",[s])).rows[0];
 await as(1,'select set_job_qualification($1,$2,\'revoke\',\'Role changed\',$3,$4)',['Jordan.D',s,f.version,crypto.randomUUID()]);
 assert.equal((await read(5)).self.is_manager,false);
 }finally{await db.close()}
});

test('directory reviews SHL codes, rejects conflicting codes, preserves GM/IT, and supports future logins',async()=>{
 const {db,as,read}=await fixture();try{
 const exp=async()=>(await as(1,'select directory_csv_export() r')).rows[0].r;
 let row=(await exp()).find(r=>r.staff_id==='Casey.W');row={...row,primary_job:'sSHL',earned_jobs:['sshl']};
 let review=(await as(1,'select directory_csv_review($1) r',[[row]])).rows[0].r;
 const id=crypto.randomUUID();const args=[[row],review.fingerprint,id];
 await as(1,'select directory_csv_apply($1,$2,$3)',args);await as(1,'select directory_csv_apply($1,$2,$3)',args);
 assert.equal((await read(4)).self.is_manager,true);
 row=(await exp()).find(r=>r.staff_id==='Casey.W');
 await assert.rejects(as(1,'select directory_csv_review($1)',[[{...row,earned_jobs:['hSHL']}]]),/one SHL code/);
 await db.exec("insert into staff(first_name,last_name,department) values('New','Leader','FOH')");
 const job=(await db.query("select id from training_positions where name='sSHL'")).rows[0].id;
 await as(1,'select set_job_qualification(\'New.L\',$1,\'override\',\'Experienced\',0,$2)',[job,crypto.randomUUID()]);
 await db.query('insert into private.employee_accounts(id,staff_id) values($1,\'New.L\')',[uid(6)]);
 assert.equal((await read(6)).self.is_manager,true);
 // GM/IT remain privileged even when they also hold an hourly office code.
 await db.exec("insert into staff(first_name,last_name,department) values('IT','Leader','FOH')");
 await db.query('update manager_profiles set linked_staff_id=\'IT.L\' where id=$1',[uid(1)]);
 await db.query('insert into private.employee_accounts(id,staff_id) values($1,\'IT.L\')',[uid(1)]);
 // Keep the existing CA login separate: changing its job must not modify the IT login.
 const hjob=(await db.query("select id from training_positions where name='hSHL'")).rows[0].id;
 await as(1,'select set_job_qualification(\'IT.L\',$1,\'override\',\'Office eligibility\',0,$2)',[hjob,crypto.randomUUID()]);
 assert.equal((await read(1)).self.is_admin,true);
 // Salary imports must not turn an hourly amount into salaried compensation.
 const result=(await as(1,'select preview_employee_import($1,\'2030-09-01\') r',[[{first_name:'Salary',last_name:'Leader',primary_role:'sSHL',other_roles:[],hourly_wage:'20',choice:'create'}]])).rows[0].r;
 assert.match(result.errors.join(' '),/Hourly wages cannot/);
 }finally{await db.close()}
});
