import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture} from './scheduler-fixture.mjs';
async function setup(){const f=await fixture();for(const name of ['029_planning_reviews','032_staff_meetings'])await f.db.exec(await readFile(new URL(`../supabase/migrations/${name}.sql`,import.meta.url),'utf8'));return f}
const call=(f,n,p,id=crypto.randomUUID())=>f.as(n,'select staff_meeting_save($1,$2) r',[JSON.stringify(p),id]);
const read=async(f,n,employee=false)=>(await f.as(n,'select staff_meetings_read($1) r',[employee])).rows[0].r.meetings;
const payload={action:'create',title:'GSR staff meeting',start:'2030-09-02T18:00:00Z',end:'2030-09-02T19:00:00Z',mode:'separate',people:['s:Casey.W','s:Jordan.D']};
async function release(f){const d=(await f.read(1)).week.draft;const review=await f.act(1,'review',{id:d.id,version:d.version});await f.act(1,'release',{id:d.id,version:d.version,fingerprint:review.planning.fingerprint,acknowledged:true,review_reason:'Reviewed staff meeting hours and coverage'})}
test('group meetings use private draft Training blocks, release privacy, idempotency and creator cancellation',async()=>{
 const f=await setup();try{
 await assert.rejects(call(f,4,payload),/manager/);
 const retry=crypto.randomUUID();await call(f,1,payload,retry);await call(f,1,payload,retry);
 let d=(await f.read(1)).week.draft;assert.equal(d.shifts.length,2);assert.ok(d.shifts.every(s=>s.assignment_type==='training'));assert.equal((await read(f,4,true)).length,0);assert.equal((await read(f,1,true)).length,0);
 const m=(await read(f,1))[0];assert.equal(m.attendees.length,2);await assert.rejects(call(f,2,{action:'cancel',id:m.id,version:1}),/creator/);
 await assert.rejects(f.act(1,'save',{id:d.id,version:d.version,shifts:[]}),/Staff meetings/);
 await release(f);assert.equal((await read(f,4,true))[0].status,'Published');assert.equal((await read(f,4,true))[0].attendees,null);assert.equal((await read(f,3,true)).length,0);
 await assert.rejects(f.as(4,'select * from private.staff_meetings'),/permission/);
 await call(f,1,{action:'cancel',id:m.id,version:1});assert.equal((await read(f,4,true))[0].status,'Published');await release(f);assert.equal((await read(f,4,true)).length,0);
 assert.equal((await f.db.query('select count(*) n from meetings')).rows[0].n,0);assert.equal((await f.db.query('select count(*) n from training_sessions')).rows[0].n,0);
 }finally{await f.db.close()}
});
test('during-shift group meetings split work without duplicate hours and restore it on cancellation',async()=>{
 const f=await setup();try{
 const {id}=await f.act(1,'draft',{week:'2030-09-01'});const original=f.shift(1);await f.act(1,'save',{id,version:1,shifts:[original]});
 await call(f,1,{...payload,mode:'within',people:['s:Casey.W']});let d=(await f.read(1)).week.draft;assert.equal(d.shifts.length,3);assert.equal(d.shifts.reduce((n,s)=>n+(Date.parse(s.end)-Date.parse(s.start))/36e5,0),5);
 const m=(await read(f,1))[0];await call(f,1,{action:'cancel',id:m.id,version:1});d=(await f.read(1)).week.draft;assert.equal(d.shifts.length,1);assert.equal(d.shifts[0].id,original.id);assert.equal(Date.parse(d.shifts[0].end),Date.parse(original.end));
 await assert.rejects(call(f,1,{...payload,mode:'within'}),/covering|cover/);assert.equal((await f.read(1)).week.draft.shifts.length,1);
 }finally{await f.db.close()}
});
