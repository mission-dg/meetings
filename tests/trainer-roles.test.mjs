import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture} from './scheduler-fixture.mjs';
test('trainer roles are job-specific, validated server-side, and preserve existing session history',async()=>{
 const {db,as,act,read,shift,gsr}=await fixture();try{
 const other=(await db.query("select id from training_positions where name='Prep'")).rows[0].id;
 await db.query('update staff set trainer_job_ids=$1 where id=$2',[[other],'Alex.L']);
 assert.deepEqual((await read(1)).people.find(p=>p.staff_id==='Alex.L').trainer_job_ids,[other]);
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;
 await act(1,'save',{id:d.id,version:d.version,shifts:[shift(1),shift(2,'s:Alex.L')]});d=(await read(1)).week.draft;
 const insert=()=>as(1,"insert into training_sessions(staff_id,trainer_id,training_position_id,shift,scheduled_at,ends_at,work_shift_id,trainer_shift_id,schedule_revision_id) values('Casey.W','Alex.L',$1,1,'2030-09-02T17:00Z','2030-09-02T18:00Z',$2,$3,$4) returning id",[gsr,shift(1).id,shift(2).id,d.id]);
 await assert.rejects(insert(),/designated for this job/);
 assert.equal((await db.query('select count(*) n from training_sessions')).rows[0].n,0);
 await db.query('update staff set trainer_job_ids=$1 where id=$2',[[other,gsr,gsr],'Alex.L']);
 assert.equal((await db.query("select cardinality(trainer_job_ids) n from staff where id='Alex.L'")).rows[0].n,2);
 const id=(await insert()).rows[0].id;
 await db.query("update staff set trainer_job_ids=$1 where id='Alex.L'",[[other]]);
 await as(1,"update training_sessions set status='Cancelled' where id=$1",[id]);
 assert.equal((await db.query('select status from training_sessions where id=$1',[id])).rows[0].status,'Cancelled');
 await assert.rejects(db.query("update staff set trainer_job_ids='{}' where id='Alex.L'"),/at least one/);
 await db.query("update staff set is_trainer=false where id='Alex.L'");
 assert.deepEqual((await read(1)).people.find(p=>p.staff_id==='Alex.L').trainer_job_ids,[]);
 }finally{await db.close()}
});
