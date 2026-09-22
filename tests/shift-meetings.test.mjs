import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,uid,sid} from './scheduler-fixture.mjs';
import {categoryHours,assignmentGroup} from '../src/scheduleDisplay.ts';
test('dedicated Training is an exclusive hours category and does not create progress or meeting credit',async()=>{
 const {db,act,read,shift}=await fixture();try{
 await act(1,'draft',{week:'2030-09-01'});const d=(await read(1)).week.draft;
 const work=shift(1),training={...shift(2,'s:Casey.W','2030-09-02T21:00Z','2030-09-02T23:00Z'),job_id:null,assignment_type:'training',activity_title:'DT Recertification'};
 await act(1,'save',{id:d.id,version:d.version,shifts:[work,training]});const data=await read(1);assert.equal(data.week.draft.shifts.length,2);
 assert.equal(assignmentGroup(training,data.jobs),'Training');const sums=categoryHours([work,training,training],data.people,data.jobs);assert.equal(sums.FOH,5);assert.equal(sums.Training,2);assert.equal(sums.Total,7);
 assert.equal((await db.query('select count(*) n from training_sessions')).rows[0].n,0);assert.equal((await db.query('select count(*) n from meetings')).rows[0].n,0);
 const current=data.week.draft;await assert.rejects(act(1,'save',{id:current.id,version:current.version,shifts:[{...training,activity_title:''}]}),/activity title/);
 }finally{await db.close()}
});
async function setup(){const f=await fixture();const {db,act,read,shift}=f;await db.exec('update manager_profiles set on_roster=true');await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;const e=shift(10),g={...shift(11,'m:'+uid(2)),job_id:null};await act(1,'save',{id:d.id,version:d.version,shifts:[e,g]});d=(await read(1)).week.draft;return {...f,d,e,g};}
const payload=(d,e,g,extra={})=>({revision_id:d.id,revision_version:d.version,work_shift_id:e.id,manager_shift_id:g.id,manager_id:uid(2),type:'Routine',...extra});
async function book(f,p,id=crypto.randomUUID(),actor=1){return (await f.as(actor,'select save_shift_meeting($1,$2) r',[p,id])).rows[0].r;}
test('shift check-ins: draft privacy, overlap, ownership, retries, publication and completion',async()=>{
 const f=await setup();const {db,as,act,read,e,g}=f;try{
 const batch=crypto.randomUUID(),p=payload(f.d,e,g);await assert.rejects(book(f,p,crypto.randomUUID(),4),/manager access/);
 const m=await book(f,p,batch);assert.equal((await book(f,p,batch)).id,m.id);
 let d=(await read(1)).week.draft;assert.ok(d.version>f.d.version);
 assert.equal((await read(4)).shift_meetings.length,0);assert.equal((await read(3)).shift_meetings.length,0);
 const empAsAdmin=(await as(1,"select workspace_read('2030-09-01','employee') r")).rows[0].r;assert.equal(empAsAdmin.shift_meetings.length,0);assert.equal(empAsAdmin.meeting_due.length,0);
 await assert.rejects(book(f,payload(d,e,g,{id:m.id,version:m.version}),crypto.randomUUID(),2),/creator/);
 await assert.rejects(act(1,'save',{id:d.id,version:d.version,shifts:[e]}),/meeting/);
 await assert.rejects(act(1,'save',{id:d.id,version:d.version,shifts:[e,{...g,start:'2030-09-02T22:00Z',end:'2030-09-02T23:00Z'}]}),/overlap/);
 await assert.rejects(book(f,payload(d,e,g)),/one_open_routine|duplicate/);
 await act(1,'release',{id:d.id,version:d.version});
 const visible=(await read(4)).shift_meetings;assert.equal(visible.length,1);assert.equal(visible[0].manager,'Manager');assert.equal((await read(3)).shift_meetings.length,0);assert.equal((await read(4)).meeting_due.length,0);
 await as(1,"update meetings set status='Completed',completed_on='2026-09-21' where id=$1",[m.id]);
 assert.equal((await read(4)).shift_meetings[0].status,'Completed');
 }finally{await db.close()}
});
test('queued check-ins cannot change; stale reviews and non-overlapping or Training shifts rejected',async()=>{
 const f=await setup();const {db,as,act,read,e,g}=f;try{
 const m=await book(f,payload(f.d,e,g));let d=(await read(1)).week.draft;
 await assert.rejects(book(f,payload(f.d,e,g,{id:m.id,version:m.version})),/Schedule changed/);
 await act(1,'queue',{id:d.id,version:d.version,release_at:'2030-09-01T12:00:00Z'});
 await assert.rejects(as(1,"update meetings set status='Cancelled' where id=$1",[m.id]),/queued/);
 d=(await read(1)).week.draft;await act(1,'unqueue',{id:d.id,version:d.version});
 await as(1,"update meetings set status='Cancelled' where id=$1",[m.id]);d=(await read(1)).week.draft;
 await act(1,'save',{id:d.id,version:d.version,shifts:[e,{...g,start:'2030-09-02T22:00Z',end:'2030-09-02T23:00Z'}]});d=(await read(1)).week.draft;
 await assert.rejects(book(f,payload(d,e,g)),/overlap/);
 await act(1,'save',{id:d.id,version:d.version,shifts:[{...e,job_id:null,assignment_type:'training',activity_title:'Recertification'},g]});d=(await read(1)).week.draft;
 await assert.rejects(book(f,payload(d,e,g)),/Training block/);
 }finally{await db.close()}
});
test('link legacy booking keeps ID and original timestamp; published reassignments cannot break it',async()=>{
 const f=await setup();const {db,as,act,read,e,g}=f;try{
 const legacy=(await as(1,"select to_jsonb(schedule_meeting('Casey.W',$1,'Routine','2030-09-02T18:00Z')) r",[uid(2)])).rows[0].r;
 await act(1,'release',{id:f.d.id,version:f.d.version});const pub=(await read(1)).published[0];
 const m=await book(f,payload({id:pub.revision_id,version:pub.version},e,g,{id:legacy.id,version:legacy.version}));assert.equal(m.id,legacy.id);assert.equal(new Date(m.scheduled_at).toISOString(),'2030-09-02T18:00:00.000Z');
 let d;
 await act(1,'draft',{week:'2030-09-01'});d=(await read(1)).week.draft;
 await assert.rejects(act(1,'save',{id:d.id,version:d.version,shifts:[{...e,person_id:'s:Jordan.D'},g]}),/participants/);
 }finally{await db.close()}
});

test('overnight check-in accepts a published manager shift across the Sunday boundary',async()=>{
 const f=await fixture();const {db,as,act,read,shift}=f;try{
 await db.exec('update manager_profiles set on_roster=true');
 const rd=async week=>(await as(1,'select scheduler_read($1) r',[week])).rows[0].r;
 const g={...shift(80,'m:'+uid(2),'2030-09-01T03:00Z','2030-09-01T10:00Z'),job_id:null};
 await act(1,'draft',{week:'2030-08-25'});let d=(await rd('2030-08-25')).week.draft;
 await act(1,'save',{id:d.id,version:d.version,shifts:[g]});d=(await rd('2030-08-25')).week.draft;await act(1,'release',{id:d.id,version:d.version});
 await act(1,'draft',{week:'2030-09-01'});d=(await read(1)).week.draft;
 const e=shift(81,'s:Casey.W','2030-09-01T06:00Z','2030-09-01T10:00Z');await act(1,'save',{id:d.id,version:d.version,shifts:[e]});d=(await read(1)).week.draft;
 const m=await book(f,payload(d,e,g));assert.ok(m.id);
 await act(1,'draft',{week:'2030-08-25'});const gd=(await rd('2030-08-25')).week.draft;
 // The employee draft remains private; its release still revalidates manager coverage.
 await act(1,'save',{id:gd.id,version:gd.version,shifts:[]});const gd2=(await rd('2030-08-25')).week.draft;await act(1,'release',{id:gd2.id,version:gd2.version});
 d=(await read(1)).week.draft;await assert.rejects(act(1,'release',{id:d.id,version:d.version}),/meeting|work shifts|issues/i);
 }finally{await db.close()}
});
