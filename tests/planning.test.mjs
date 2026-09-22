import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture,uid,sid} from './scheduler-fixture.mjs';
async function setup(){const f=await fixture();await f.db.exec(await readFile(new URL('../supabase/migrations/029_planning_reviews.sql',import.meta.url),'utf8'));return f}
const rpc=async(f,n,name,args)=>(await f.as(n,`select ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) r`,args)).rows[0].r;
async function draft(f,shifts,week='2030-09-01'){const {id}=await f.act(1,'draft',{week});await f.act(1,'save',{id,version:1,shifts});return id}
async function release(f,id){const r=await f.act(1,'review',{id,version:2});return f.act(1,'release',{id,version:2,fingerprint:r.planning.fingerprint,acknowledged:true,review_reason:'Reviewed pilot hours and staffing'})}
function dayRule(gsr){return {dow:1,lunch_percent:40,periods:[{name:'Lunch',start:'11:00',end:'16:00',bands:[{min:0,max:1000,jobs:{[gsr]:1}},{min:1000,max:null,jobs:{[gsr]:2}}]},{name:'Dinner',start:'16:00',end:'21:00',bands:[{min:0,max:null,jobs:{[gsr]:1}}]}]}}
async function assessment(f,shifts,weeks=['2030-09-01']){return (await f.db.query('select private.planning_assessment($1,$2) r',[JSON.stringify(shifts),weeks])).rows[0].r}
test('hours thresholds, assignment deduplication, weekly boundaries and actual DST elapsed duration',async()=>{
 const f=await setup();try{
 for(const h of [34.99,35,40,40.01]){const s=f.shift(1);s.end=new Date(Date.parse(s.start)+h*3600000).toISOString();const a=await assessment(f,[s,s]);assert.equal(a.hours[0].hours,h)}
 const s=f.shift(2,'s:Casey.W','2030-09-08T04:00:00Z','2030-09-08T07:00:00Z');let a=await assessment(f,[s],['2030-09-01','2030-09-08']);assert.deepEqual(a.hours.map(x=>x.hours),[1,2]);
 const dst=f.shift(3,'s:Casey.W','2030-03-10T07:00:00Z','2030-03-10T09:00:00Z');a=await assessment(f,[dst],['2030-03-10']);assert.equal(a.hours[0].hours,2);
 await f.db.exec(`update manager_profiles set employment_type='Salaried' where id='${uid(2)}'`);a=await assessment(f,[f.shift(4,'m:'+uid(2))]);assert.equal(a.hours.length,0);
 const training={...f.shift(5),assignment_type:'training',job_id:null,activity_title:'Recertification'};assert.equal((await assessment(f,[training])).hours[0].hours,5);
 }finally{await f.db.close()}
});
test('coverage targets, explicit zero forecasts, split reconciliation, overrides and stale versions',async()=>{
 const f=await setup();try{
 const save=(n,k,p)=>rpc(f,n,'coverage_save',[k,JSON.stringify(p),crypto.randomUUID()]);
 await assert.rejects(save(2,'rules',{version:1,days:[dayRule(f.gsr)]}),/GM or IT/);
 await save(1,'rules',{version:1,days:[dayRule(f.gsr)]});
 await assert.rejects(save(1,'rules',{version:1,days:[]}),/changed/);
 await assert.rejects(save(1,'forecast',{day:'2030-09-02',total:1000,lunch:500,dinner:600,version:0,period_version:0}),/adding up/);
 await save(2,'forecast',{day:'2030-09-02',total:2000,lunch:1000,dinner:1000,version:0,period_version:0});
 const work=f.shift(1,'s:Casey.W','2030-09-02T16:00:00Z','2030-09-02T23:00:00Z');let a=await assessment(f,[work]);assert.equal(a.missing.length,6);assert.equal(a.coverage.find(c=>c.period==='Lunch').needed,2);assert.equal(a.coverage.find(c=>c.period==='Lunch').shortage,1);assert.equal(a.coverage.filter(c=>c.period==='Dinner').length,2);
 await save(2,'override',{day:'2030-09-02',version:0,reason:'Local event adjustment',targets:[{name:'Lunch',jobs:{[f.gsr]:1}},{name:'Dinner',jobs:{[f.gsr]:0}}]});a=await assessment(f,[work]);assert.equal(a.coverage[0].shortage,0);assert.ok(a.coverage.some(c=>c.excess===1));
 await save(2,'override',{day:'2030-09-02',version:1,reason:'Restore expected demand',remove:true});
 const tr={...work,assignment_type:'training',job_id:null,activity_title:'Recert'};a=await assessment(f,[tr]);assert.equal(a.coverage[0].scheduled,0);
 await assert.rejects(rpc(f,4,'coverage_read',['2030-09-01']),/Manager/);
 await assert.rejects(rpc(f,3,'planning_read',['2030-09-01',null,null]),/Manager/);
 }finally{await f.db.close()}
});
test('release review cannot be bypassed, is retry-safe, and queued changes hold publication',async()=>{
 const f=await setup();try{
 const id=await draft(f,[f.shift(1)]);const r=await f.act(1,'review',{id,version:2});assert.equal(r.planning.missing.length,7);
 await assert.rejects(f.act(1,'release',{id,version:2}),/changed/);
 await assert.rejects(f.act(1,'release',{id,version:2,fingerprint:r.planning.fingerprint}),/Acknowledge/);
 const p={id,version:2,fingerprint:r.planning.fingerprint,acknowledged:true,review_reason:'Pilot staffing setup pending',release_at:'2030-08-30T12:00:00Z'};const sub=sid(9991);
 await f.act(1,'queue',p,sub);await f.act(1,'queue',p,sub);
 await rpc(f,1,'coverage_save',['rules',JSON.stringify({version:1,days:[dayRule(f.gsr)]}),crypto.randomUUID()]);
 assert.equal((await f.read(1)).week.draft.state,'Attention');assert.equal((await f.read(1)).week.published_id,null);
 assert.equal(Number((await f.db.query('select count(*) n from private.planning_reviews')).rows[0].n),1);
 }finally{await f.db.close()}
});
test('trade choices are server-qualified, approval is reviewed, denials need reasons, and privacy holds',async()=>{
 const f=await setup();try{
 await rpc(f,1,'set_job_qualification',['Alex.L',f.gsr,'override','Experienced employee',0,crypto.randomUUID()]);
 await rpc(f,1,'set_job_qualification',['Casey.W',f.gsr,'override','Experienced employee',0,crypto.randomUUID()]);
 const id=await draft(f,[f.shift(1),f.shift(2,'s:Alex.L','2030-09-03T16:00:00Z','2030-09-03T21:00:00Z')]);await release(f,id);
 const options=await rpc(f,4,'trade_options',[f.shift(1).id]);assert.ok(options.people.some(p=>p.id==='s:Alex.L'));assert.ok(!options.people.some(p=>p.id==='s:Jordan.D'));assert.equal(options.trades.length,1);
 const q=await f.act(4,'request',{kind:'Trade',source_id:f.shift(1).id,target_id:f.shift(2).id});await f.act(3,'accept',{id:q.id,version:1});
 const a=await rpc(f,2,'planning_read',['2030-09-01',null,q.id]);assert.equal(a.coverage_unchanged,true);
 await assert.rejects(f.act(2,'decide',{id:q.id,version:2,decision:'Approved'}),/changed/);
 await assert.rejects(f.act(2,'decide',{id:q.id,version:2,decision:'Rejected',response:''}),/reason/);
 await f.act(2,'decide',{id:q.id,version:2,decision:'Approved',fingerprint:a.fingerprint,acknowledged:true,review_reason:'Reviewed unchanged pilot coverage'});
 const data=await f.read(4);assert.equal(data.published[0].shifts.find(s=>s.id===f.shift(1).id).person_id,'s:Alex.L');assert.ok(!JSON.stringify(data).includes('review_reason'));
 await assert.rejects(rpc(f,4,'planning_read',['2030-09-01',null,q.id]),/Manager/);
 }finally{await f.db.close()}
});
test('fully configured coverage isolates 35-hour acknowledgment, and the unattended worker publishes only once',async()=>{
 const f=await setup();try{
 const rule=dayRule(f.gsr);for(const p of rule.periods)p.bands=[{min:0,max:null,jobs:{[f.gsr]:0}}];
 await rpc(f,1,'coverage_save',['rules',JSON.stringify({version:1,days:Array.from({length:7},(_,dow)=>({...rule,dow}))}),crypto.randomUUID()]);
 for(let i=1;i<=7;i++)await rpc(f,1,'coverage_save',['forecast',JSON.stringify({day:'2030-09-0'+i,total:0,lunch:0,dinner:0,version:0,period_version:0}),crypto.randomUUID()]);
 const shifts=Array.from({length:7},(_,i)=>f.shift(10+i,'s:Casey.W',`2030-09-0${i+1}T16:00:00Z`,`2030-09-0${i+1}T21:00:00Z`));
 let a=await assessment(f,shifts);assert.equal(a.missing.length,0);assert.equal(a.requires_ack,true);assert.equal(a.hours[0].hours,35);
 a=await assessment(f,shifts.slice(1));assert.equal(a.requires_ack,false);
 const id=await draft(f,shifts);let r=await f.act(1,'review',{id,version:2});
 await assert.rejects(f.act(1,'queue',{id,version:2,release_at:'2030-08-31T10:00:00Z',fingerprint:r.planning.fingerprint}),/Acknowledge/);
 await f.act(1,'queue',{id,version:2,release_at:'2030-08-31T10:00:00Z',fingerprint:r.planning.fingerprint,acknowledged:true,review_reason:'35 hours reviewed'});
 await f.db.exec(`update private.schedule_revisions set release_at=now()-interval '1 second' where id='${id}';select private.run_schedule_releases();select private.run_schedule_releases();`);
 assert.equal((await f.read(1)).week.published_id,id);
 assert.equal(Number((await f.db.query("select count(*) n from private.scheduler_notifications where event_key=$1",['schedule:'+id])).rows[0].n),1);
 await assert.rejects(f.act(1,'unqueue',{id,version:3}),/changed|current draft/);
 }finally{await f.db.close()}
});
test('competing offers, linked meetings, rejected eligibility and changed impact cannot assign twice',async()=>{
 const f=await setup();try{
 for(const p of ['Alex.L','Casey.W','Jordan.D'])await rpc(f,1,'set_job_qualification',[p,f.gsr,'override','Experienced employee',0,crypto.randomUUID()]);
 const id=await draft(f,[f.shift(1)]);await release(f,id);
 const a=await f.act(4,'request',{kind:'Offer',source_id:f.shift(1).id});
 await f.act(3,'accept',{id:a.id,version:1});await assert.rejects(f.act(5,'accept',{id:a.id,version:1}),/changed/);
 const review=await rpc(f,2,'planning_read',['2030-09-01',null,a.id]);
 await rpc(f,1,'coverage_save',['rules',JSON.stringify({version:1,days:[dayRule(f.gsr)]}),crypto.randomUUID()]);
 await assert.rejects(f.act(2,'decide',{id:a.id,version:2,decision:'Approved',fingerprint:review.fingerprint,acknowledged:true,review_reason:'Old assessment'}),/changed/);
 assert.equal((await f.read(4)).published[0].shifts[0].person_id,'s:Casey.W');
 const latest=await rpc(f,2,'planning_read',['2030-09-01',null,a.id]);await f.act(2,'decide',{id:a.id,version:2,decision:'Approved',fingerprint:latest.fingerprint,acknowledged:true,review_reason:'New assessment reviewed'});
 await assert.rejects(f.act(2,'decide',{id:a.id,version:2,decision:'Approved',fingerprint:latest.fingerprint,acknowledged:true,review_reason:'Repeat changed submission'}),/accepted|pending|changed/i);
 await assert.rejects(rpc(f,4,'scheduler_action_before_planning',['draft',JSON.stringify({week:'2030-09-08'}),crypto.randomUUID()]),/permission denied/);
 }finally{await f.db.close()}
});
