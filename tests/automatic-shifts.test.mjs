import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture} from './scheduler-fixture.mjs';
test('automatic shifts support multiple jobs, preserve slots, and still flag overlaps',async()=>{
 const {db,act,read,shift}=await fixture();try{
 const jobs=(await db.query("select name,id from training_positions where department='FOH' and name in ('CA','TA')")).rows;
 assert.equal(jobs.length,2);
 await act(1,'draft',{week:'2030-09-01'});let draft=(await read(1)).week.draft;
 const shifts=[shift(1,'s:Casey.W','2030-09-02T16:00Z','2030-09-02T18:00Z'),{...shift(2,'s:Casey.W','2030-09-02T18:00Z','2030-09-02T20:00Z'),job_id:jobs[0].id}, {...shift(3,'s:Casey.W','2030-09-02T20:00Z','2030-09-02T22:00Z'),job_id:jobs[1].id}];
 let result=await act(1,'save',{id:draft.id,version:draft.version,shifts:shifts.toReversed()});assert.deepEqual(result.issues,[]);
 draft=(await read(1)).week.draft;assert.deepEqual(draft.shifts.map(s=>s.slot),[1,2,3]);
 result=await act(1,'save',{id:draft.id,version:draft.version,shifts:draft.shifts.slice(1).map(s=>({...s,slot:99}))});assert.deepEqual(result.issues,[]);
 draft=(await read(1)).week.draft;assert.deepEqual(draft.shifts.map(s=>s.slot),[2,3]);
 result=await act(1,'save',{id:draft.id,version:draft.version,shifts:[...draft.shifts,shift(4,'s:Casey.W','2030-09-02T19:00Z','2030-09-02T21:00Z')]});assert.match(result.issues.join(' '),/Overlapping/);
 await assert.rejects(act(4,'save',{id:draft.id,version:draft.version,shifts:[]}),/manager|Manager|access/);
 }finally{await db.close()}
});
