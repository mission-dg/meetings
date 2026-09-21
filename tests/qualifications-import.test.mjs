import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,uid} from './scheduler-fixture.mjs';
import {parseEmployees} from '../src/importCsv.ts';
import {hourlyShifts,shiftLabel} from '../src/scheduler.ts';
test('qualifications: experienced overrides, manager sign-off limits and private audit',async()=>{
 const {db,as,gsr,read}=await fixture();try{
 const set=(actor,action,version=0,reason='Prior experience')=>as(actor,'select set_job_qualification($1,$2,$3,$4,$5,$6) r',['Casey.W',gsr,action,reason,version,crypto.randomUUID()]);
 await assert.rejects(set(2,'override'),/GM or IT/);await assert.rejects(set(2,'signoff'),/target number/);
 const f=(await set(1,'override')).rows[0].r;assert.equal(f.origin,'experience');assert.equal((await db.query('select count(*) n from training_sessions')).rows[0].n,0);
 assert.equal((await read(4)).signoffs[0].origin,'experience');await assert.rejects(as(4,'select * from private.qualification_history'),/permission denied/);
 await assert.rejects(set(2,'revoke',f.version),/GM or IT/);await assert.rejects(set(1,'revoke',f.version,''),/reason/);
 await set(1,'revoke',f.version);assert.equal((await read(4)).signoffs.some(f=>f.active),false);
 await db.exec(`update manager_profiles set is_gm=true where id='${uid(2)}'`);await set(2,'override');
 }finally{await db.close()}
});
test('office: classification permissions, regular jobs, separate blocks and salaried hours',async()=>{
 const {db,as,act,read,shift}=await fixture();try{
 await as(1,'select set_shl_employment($1,$2,$3)',['m:'+uid(2),'Hourly',1]);
 await assert.rejects(as(2,'select set_shl_employment($1,$2,$3)',['m:'+uid(1),'Salaried',1]),/GM or IT/);
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;
 const regular=shift(1,'m:'+uid(2));const office={...shift(2,'m:'+uid(2),'2030-09-02T21:00Z','2030-09-02T22:00Z'),assignment_type:'closing_office',job_id:null};
 assert.deepEqual((await act(1,'save',{id:d.id,version:d.version,shifts:[regular,office]})).issues,[]);
 d=(await read(1)).week.draft;
 await assert.rejects(act(1,'save',{id:d.id,version:d.version,shifts:[{...office,person_id:'s:Casey.W'}]}),/classified SHL/);
 const overlap={...office,start:'2030-09-02T20:00Z'};assert.match((await act(1,'save',{id:d.id,version:d.version,shifts:[regular,overlap]})).issues.join(),/Overlapping/);
 const data=await read(1);assert.equal(data.people.find(p=>p.id==='m:'+uid(2)).employment_type,'Hourly');
 const salaried=[{id:'m:'+uid(2),employment_type:'Salaried'}];assert.deepEqual(hourlyShifts([regular,office],salaried),[]);assert.equal(shiftLabel(office,[]),'Closing office');
 }finally{await db.close()}
});
test('migration import: matching, atomic updates, wage dates, earned roles, replay and stale review',async()=>{
 const {db,as,gsr}=await fixture();try{
 const preview=async(rows,date='2030-09-01')=>(await as(1,'select preview_employee_import($1,$2) r',[JSON.stringify(rows),date])).rows[0].r;
 const apply=async(rows,r,batch=crypto.randomUUID())=>(await as(1,'select admin_import_staff($1,$2,$3,$4) r',[batch,JSON.stringify(rows),'2030-09-01',r.fingerprint])).rows[0].r;
 const rows=[{first_name:'Casey',last_name:'Williams',primary_role:'gsr',other_roles:['EXPO','Line','Catering','EXPO'],hourly_wage:'17.50'}];
 let p=await preview(rows);assert.match(p.errors.join(),/Confirm/);rows[0].target_id='Casey.W';p=await preview(rows);assert.deepEqual(p.errors,[]);
 const batch=crypto.randomUUID();assert.deepEqual(await apply(rows,p,batch),{added:0,updated:1,skipped:0});assert.deepEqual(await apply(rows,p,batch),{added:0,updated:1,skipped:0});
 assert.equal((await db.query("select count(*) n from training_signoffs where staff_id='Casey.W' and active")).rows[0].n,4);
 assert.equal((await db.query("select hourly_rate from private.pay_rates where person_id='s:Casey.W'")).rows[0].hourly_rate,'17.50');
 assert.equal((await db.query('select count(*) n from training_sessions')).rows[0].n,0);
 const blanks=[{staff_id:'Casey.W',first_name:'Changed',last_name:'Name',active:false,primary_role:'',other_roles:[],hourly_wage:''}];p=await preview(blanks);await apply(blanks,p);
 assert.equal((await db.query("select first_name from staff where id='Casey.W'")).rows[0].first_name,'Casey');
 p=await preview(rows);await db.exec("update staff set priority=true where id='Casey.W'");await assert.rejects(apply(rows,p),/changed since review/);
 assert.match((await preview([rows[0],rows[0]])).errors.join(),/same employee/);
 assert.match((await preview([{...rows[0],other_roles:['Unknown']}])).errors.join(),/Unknown/);
 await assert.rejects(as(2,'select preview_employee_import($1,$2)',[JSON.stringify(rows),'2030-09-01']),/IT Admin/);
 const newRows=[{first_name:'New',last_name:'Person',primary_role:'DRL',department:'FOH',other_roles:['Line'],active:true,hourly_wage:'20'}];p=await preview(newRows);assert.deepEqual(p.errors,[]);await apply(newRows,p);assert.equal((await db.query("select count(*) n from staff where first_name='New'")).rows[0].n,1);
 }finally{await db.close()}
});
test('import parser accepts quoted comma-separated earned roles',()=>{
 const r=parseEmployees('First Name,Last Name,Primary Role,Other Roles,Hourly Wage\nAlex,Example,GSR,"EXPO, DRL, Catering",17.50\n')[0];assert.deepEqual(r.other_roles,['EXPO','DRL','Catering']);assert.equal(r.primary_role,'GSR');assert.equal(r.hourly_wage,'17.50');
});
test('migration preview rejects conflicts; inactive history and dated wages are preserved',async()=>{
 const {db,as}=await fixture();try{
 const inspect=async rows=>(await as(1,'select preview_employee_import($1,$2) r',[JSON.stringify(rows),'2030-09-01'])).rows[0].r;
 const apply=async(rows,p)=>(await as(1,'select admin_import_staff($1,$2,$3,$4) r',[crypto.randomUUID(),JSON.stringify(rows),'2030-09-01',p.fingerprint])).rows[0].r;
 await db.exec("insert into staff(first_name,last_name,department) values('Casey','Williams','BOH');");
 assert.match((await inspect([{first_name:'Casey',last_name:'Williams',primary_role:'GSR'}])).errors.join(),/Multiple/);
 assert.match((await inspect([{staff_id:'Unknown',primary_role:'GSR'}])).errors.join(),/Unknown Staff ID/);
 assert.match((await inspect([{staff_id:'Casey.W',primary_role:'GSR',department:'BOH'}])).errors.join(),/conflicts/);
 assert.match((await inspect([{staff_id:'Casey.W',hourly_wage:'17.555'}])).errors.join(),/decimal/);
 const invalid=[{first_name:'Batch',last_name:'Person',primary_role:'GSR',active:true},{staff_id:'Casey.W',primary_role:'Not a job'}],p=await inspect(invalid);await assert.rejects(apply(invalid,p),/Unknown/);assert.equal((await db.query("select count(*) n from staff where first_name='Batch'")).rows[0].n,0);
 await db.exec("update staff set active=false where id='Casey.W';insert into private.pay_rates(person_id,effective,hourly_rate) values('s:Casey.W','2030-01-01',15),('s:Casey.W','2030-09-01',16);");
 const rows=[{staff_id:'Casey.W',primary_role:'GSR',other_roles:['Line'],hourly_wage:'18.50'}];const review=await inspect(rows);assert.equal(review.rows[0].before.wage_on_date,16);await apply(rows,review);
 assert.equal((await db.query("select active from staff where id='Casey.W'")).rows[0].active,false);
 assert.equal((await db.query("select count(*) n from private.pay_rates where person_id='s:Casey.W'")).rows[0].n,2);
 await db.exec(`update manager_profiles set linked_staff_id='Alex.L',employment_type='Salaried' where id='${uid(2)}'`);
 assert.match((await inspect([{staff_id:'Alex.L',hourly_wage:'20'}])).errors.join(),/salaried/);
 for(const actor of [3,4])await assert.rejects(as(actor,'select preview_employee_import($1,$2)',[JSON.stringify(rows),'2030-09-01']),/IT Admin/);
 }finally{await db.close()}
});
test('manager employee edits derive primary group and reject stale edits and qualification bypasses',async()=>{
 const {db,as}=await fixture();try{
 const line=(await db.query("select id from training_positions where name='Line'")).rows[0].id;
 const s=(await db.query("select * from staff where id='Casey.W'")).rows[0];const values={...s,primary_job_id:line};
 await as(2,'select save_employee($1,$2,$3)',['Casey.W',s.version,JSON.stringify(values)]);
 const updated=(await db.query("select * from staff where id='Casey.W'")).rows[0];assert.equal(updated.department,'BOH');assert.equal(updated.id,s.id);
 await assert.rejects(as(2,'select save_employee($1,$2,$3)',['Casey.W',s.version,JSON.stringify(values)]),/changed/);
 await assert.rejects(as(2,'select save_employee($1,$2,$3)',['Casey.W',updated.version,JSON.stringify({...values,first_name:'Changed'})]),/IT manages/);
 await assert.rejects(as(4,'select save_employee($1,$2,$3)',['Casey.W',updated.version,JSON.stringify(values)]),/Manager/);
 await assert.rejects(as(1,'insert into training_signoffs(staff_id,training_position_id,origin) values($1,$2,$3)',['Casey.W',line,'experience']),/permission/);
 }finally{await db.close()}
});
