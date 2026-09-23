import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture,uid} from './scheduler-fixture.mjs';
async function setup(){const f=await fixture();for(const name of ['029_planning_reviews','030_directory_positions','031_account_shl_options','032_schedule_notes','033_staff_meetings','034_one_on_one_roles','035_workflow_onboarding','036_leadership_qualifications']){const files=await import('node:fs/promises').then(fs=>fs.readdir(new URL('../supabase/migrations/',import.meta.url)));const file=files.find(x=>x.startsWith(name.slice(0,3)+'_'));try{if(file.startsWith('036_'))await f.db.exec(await readFile(new URL('../supabase/maintenance/backup_before_leadership.sql',import.meta.url),'utf8'));await f.db.exec(await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'))}catch(e){await f.db.close();throw Error(name+': '+e.message+' '+e.where)}}return f}
const q=async(f,staff,job,action='override',version=0)=>(await f.as(1,'select set_job_qualification($1,$2,$3,\'Leadership test\',$4,$5) r',[staff,job,action,version,crypto.randomUUID()])).rows[0].r;
test('sSHL inherits operational jobs, protects its primary title, and restores separately earned primary on revocation',async()=>{
 const f=await setup();try{
 const s=(await f.db.query("select id from training_positions where name='sSHL'")).rows[0].id;
 await q(f,'Casey.W',f.gsr);
 await f.db.query("update staff set primary_job_id=$1 where id='Casey.W'",[f.gsr]);
 const before=(await f.db.query('select count(*) n from training_sessions')).rows[0].n;
 const leader=await q(f,'Casey.W',s);
 let st=(await f.db.query("select * from staff where id='Casey.W'")).rows[0];assert.equal(st.leadership_title,'sSHL');assert.equal(st.primary_job_id,s);assert.equal(st.previous_primary_job_id,f.gsr);assert.equal(st.is_trainer,false);
 await assert.rejects(f.db.query("update staff set primary_job_id=$1 where id='Casey.W'",[f.gsr]),/Leadership primary/);
 await f.db.exec("insert into training_positions(name,department) values('New operational job','Catering')");
 const extra=(await f.db.query("select id from training_positions where name='New operational job'")).rows[0].id;
 const quals=(await f.as(4,'select qualifications_read() r')).rows[0].r;assert.equal(quals.find(x=>x.staff_id==='Casey.W'&&x.training_position_id===extra).inherited_source,'sSHL');
 assert.equal(quals.find(x=>x.staff_id==='Casey.W'&&x.training_position_id===f.gsr&&x.active).origin,'experience');
 assert.equal((await f.db.query('select count(*) n from training_sessions')).rows[0].n,before);
 await q(f,'Casey.W',s,'revoke',leader.version);
 st=(await f.db.query("select * from staff where id='Casey.W'")).rows[0];assert.equal(st.primary_job_id,f.gsr);assert.equal(st.department,'FOH');assert.equal(st.leadership_title,null);
 const after=(await f.as(4,'select qualifications_read() r')).rows[0].r;assert.ok(after.every(x=>!x.inherited_source));assert.ok(after.some(x=>x.training_position_id===f.gsr&&x.active));
 }finally{await f.db.close()}
});
test('GM designation qualifies linked and unlinked GMs, without granting anything to IT or hSHL',async()=>{
 const f=await setup();try{
 await f.db.query('update manager_profiles set is_gm=true where id=$1',[uid(2)]);
 let d=await f.read(1);assert.equal(d.people.find(p=>p.id==='m:'+uid(2)).leadership_title,'GM');assert.ok(d.people.find(p=>p.id==='m:'+uid(2)).inherited_job_ids.includes(f.gsr));assert.deepEqual(d.people.find(p=>p.id==='m:'+uid(1)).inherited_job_ids,[]);
 await f.db.query("update manager_profiles set linked_staff_id='Jordan.D' where id=$1",[uid(2)]);
 const st=(await f.db.query("select * from staff where id='Jordan.D'")).rows[0];assert.equal(st.leadership_title,'GM');
 const g=(await f.db.query("select id from training_positions where name='GM'")).rows[0].id;assert.equal(st.primary_job_id,g);
 await assert.rejects(q(f,'Casey.W',g),/GM qualification/);
 const h=(await f.db.query("select id from training_positions where name='hSHL'")).rows[0].id;await q(f,'Casey.W',h);
 assert.equal((await f.db.query("select private.job_qualified('Casey.W',$1) q",[f.gsr])).rows[0].q,false);
 const employee=(await f.as(4,"select workspace_read('2030-09-01','employee') r")).rows[0].r;assert.ok(employee.signoffs.every(x=>x.staff_id==='Casey.W'));assert.deepEqual(employee.accounts,[]);
 await assert.rejects(f.as(4,'select * from private.effective_qualifications()'),/permission denied/);
 await f.db.exec(`begin;update manager_profiles set is_gm=false where id='${uid(2)}';update manager_profiles set is_gm=true where id='${uid(1)}';commit;`);assert.equal((await f.db.query("select primary_job_id from staff where id='Jordan.D'")).rows[0].primary_job_id,null);
 }finally{await f.db.close()}
});

test('imports, candidate assessment and future review use inherited qualifications without changing earned history',async()=>{
 const f=await setup();try{
 const s=(await f.db.query("select id from training_positions where name='sSHL'")).rows[0].id;
 const leader=await q(f,'Casey.W',s);
 const candidate=(await f.as(1,'select assignment_candidates($1,null,null,$2) r',['2030-09-01',JSON.stringify(f.shift(1))])).rows[0].r;
 assert.equal(candidate.candidates.find(x=>x.id==='s:Casey.W').warning,null);
 const exported=(await f.as(1,'select directory_csv_export() r')).rows[0].r.find(x=>x.staff_id==='Casey.W');
 await assert.rejects(f.as(1,'select directory_csv_review($1)',[[{...exported,primary_job:'GSR',earned_jobs:['GSR']}]]),/Leadership primary/);
 const importRows=[{staff_id:'Casey.W',other_roles:['GSR']}];
 let review=(await f.as(1,"select preview_employee_import($1,'2030-09-01') r",[importRows])).rows[0].r;assert.deepEqual(review.errors,[]);
 await f.as(1,"select admin_import_staff($1,$2,'2030-09-01',$3)",[crypto.randomUUID(),importRows,review.fingerprint]);
 assert.ok((await f.db.query("select id from training_signoffs where staff_id='Casey.W' and training_position_id=$1 and active",[f.gsr])).rows.length);
 const expo=(await f.db.query("select id from training_positions where name='EXPO'")).rows[0].id;
 const draft=await f.act(1,'draft',{week:'2030-09-01'});
 await f.act(1,'save',{id:draft.id,version:1,shifts:[{...f.shift(1),job_id:expo}]});
 await q(f,'Casey.W',s,'revoke',leader.version);
 const notes=(await f.read(1)).notifications;assert.ok(notes.some(x=>x.event_key.startsWith('leadership-review:')&&x.body.includes('2030-09-01')));
 const emp=(await f.as(4,"select workspace_read('2030-09-01','employee') r")).rows[0].r;assert.ok(!emp.notifications.some(x=>x.event_key.startsWith('leadership-review:')));
 assert.equal((await f.db.query("select private.job_qualified('Casey.W',$1) q",[f.gsr])).rows[0].q,true);
 }finally{await f.db.close()}
});

test('GM precedence falls back to sSHL, inactive operational jobs are not inherited, and permissions remain authoritative',async()=>{
 const f=await setup();try{
 const s=(await f.db.query("select id from training_positions where name='sSHL'")).rows[0].id;
 await q(f,'Casey.W',s);
 await f.db.exec(`begin;update manager_profiles set is_gm=false where is_gm;update manager_profiles set is_gm=true where id='${uid(4)}';commit;`);
 assert.equal((await f.db.query("select leadership_title from staff where id='Casey.W'")).rows[0].leadership_title,'GM');
 await f.db.exec(`begin;update manager_profiles set is_gm=false where is_gm;update manager_profiles set is_gm=true where id='${uid(2)}';commit;`);
 assert.equal((await f.db.query("select leadership_title from staff where id='Casey.W'")).rows[0].leadership_title,'sSHL');
 await f.db.query('update training_positions set active=false where id=$1',[f.gsr]);
 assert.equal((await f.db.query("select private.job_qualified('Casey.W',$1) q",[f.gsr])).rows[0].q,false);
 const staff=(await f.db.query("select * from staff where id='Casey.W'")).rows[0];
 await assert.rejects(f.as(5,'select save_employee($1,$2,$3)',['Casey.W',staff.version,{...staff}]),/Manager access/);
 await assert.rejects(f.as(4,'select set_job_qualification($1,$2,\'revoke\',\'reason\',1,$3)',['Casey.W',s,crypto.randomUUID()]),/GM or IT/);
 await f.db.exec('set role anon');await assert.rejects(f.db.query('select qualifications_read()'),/permission denied/);await f.db.exec('reset role');
 }finally{await f.db.close()}
});
