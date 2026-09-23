import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture,uid} from './scheduler-fixture.mjs';
import {practiceStart,practiceReduce,practiceIssues,practiceHours} from '../src/practiceModel.ts';
const rpc=async(f,n,name,args=[])=>(await f.as(n,`select ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) r`,args)).rows[0].r;
test('workflow storage: private progress, authorized versioned presets, retries, candidate assessment',async()=>{
 const f=await fixture();try{
 for(const name of ['029_planning_reviews','035_workflow_onboarding'])await f.db.exec(await readFile(new URL('../supabase/migrations/'+name+'.sql',import.meta.url),'utf8'));
 await rpc(f,4,'onboarding_save',['employee',1,'deferred',0]);assert.equal((await rpc(f,4,'onboarding_read'))[0].status,'deferred');assert.equal((await rpc(f,5,'onboarding_read')).length,0);
 await assert.rejects(rpc(f,4,'onboarding_save',['it',1,'completed',0]),/unavailable/);
 await assert.rejects(f.as(4,'select * from private.onboarding_progress'),/permission denied/);
 await assert.rejects(rpc(f,4,'shift_presets_read'),/manager required/);
 const values={name:'Lunch',job_id:f.gsr,assignment_type:'regular',start_time:'11:00',end_time:'16:00',next_day:false};const sub=crypto.randomUUID();
 const p=await rpc(f,2,'shift_preset_save',[JSON.stringify(values),sub]);assert.equal(p.version,1);assert.deepEqual(await rpc(f,2,'shift_preset_save',[JSON.stringify(values),sub]),p);
 await assert.rejects(rpc(f,2,'shift_preset_save',[JSON.stringify({...values,name:'Changed'}),sub]),/Submission changed/);
 await assert.rejects(rpc(f,2,'shift_preset_save',[JSON.stringify({...values,id:p.id,version:0}),crypto.randomUUID()]),/Preset changed/);
 await assert.rejects(rpc(f,2,'shift_preset_save',[JSON.stringify({...values,end_time:'10:00'}),crypto.randomUUID()]),/Preset must/);
 await rpc(f,2,'shift_preset_save',[JSON.stringify({...values,name:'Overnight',start_time:'22:00',end_time:'06:00',next_day:true}),crypto.randomUUID()]);
 const {id}=await f.act(1,'draft',{week:'2030-09-01'});await f.act(1,'save',{id,version:1,shifts:[f.shift(1)]});
 const shift={...f.shift(2),id:null};const candidate=await rpc(f,1,'assignment_candidates',['2030-09-01',id,2,JSON.stringify(shift)]);
 assert.ok(candidate.candidates.find(p=>p.id==='s:Casey.W').reasons.includes('Overlapping assignment'));
 const edit=await rpc(f,1,'assignment_candidates',['2030-09-01',id,2,JSON.stringify(f.shift(1))]);assert.equal(edit.candidates.find(p=>p.id==='s:Casey.W').hours,5);assert.equal(edit.candidates.find(p=>p.id==='s:Casey.W').reasons.length,0);
 await assert.rejects(rpc(f,4,'assignment_candidates',['2030-09-01',id,2,JSON.stringify(shift)]),/manager required/);
 await assert.rejects(rpc(f,1,'assignment_candidates',['2030-09-01',id,1,JSON.stringify(shift)]),/Draft changed/);
 await rpc(f,2,'shift_preset_save',[JSON.stringify({id:p.id,version:1,archive:true}),crypto.randomUUID()]);assert.equal((await rpc(f,1,'shift_presets_read')).find(x=>x.id===p.id).active,false);
 const grants=(await f.db.query("select has_function_privilege('anon','public.onboarding_read()','EXECUTE') allowed")).rows[0];assert.equal(grants.allowed,false);
 }finally{await f.db.close()}
});
test('practice manager rejects conflicts and stale reviews without live dependencies',()=>{
 let s=practiceReduce(practiceStart('manager'),{type:'draft'});assert.equal(practiceHours(s),32);
 s=practiceReduce(s,{type:'shift',shift:{id:'lunch',person:'alex',day:4,start:11,end:16,job:'GSR'}});assert.equal(practiceHours(s),37);
 s=practiceReduce(s,{type:'shift',shift:{id:'conflict',person:'alex',day:0,start:12,end:16,job:'GSR'}});assert.ok(practiceIssues(s).length);assert.throws(()=>practiceReduce(s,{type:'review',reason:'Checked'}));
 s=practiceReduce(s,{type:'remove',id:'conflict'});s=practiceReduce(s,{type:'review',reason:'Reviewed missing setup and approaching OT'});
 let changed=practiceReduce(s,{type:'remove',id:'lunch'});assert.throws(()=>practiceReduce(changed,{type:'publish'}));assert.ok(practiceReduce(s,{type:'publish'}).completed);
 assert.throws(()=>practiceReduce(practiceStart('employee'),{type:'draft'}));
});
test('practice employee acceptance sequence and IT accounts are explicit simulations',()=>{
 let s=practiceStart('employee');s=practiceReduce(s,{type:'request',kind:'Offer shift'});s=practiceReduce(s,{type:'approve',id:'request0'});assert.equal(s.requests[0].status,'Waiting on coworker');s=practiceReduce(s,{type:'accept',id:'request0'});s=practiceReduce(s,{type:'approve',id:'request0'});s=practiceReduce(s,{type:'request',kind:'Time off'});s=practiceReduce(s,{type:'approve',id:'request1'});assert.ok(s.completed);
 let it=practiceReduce(practiceStart('it'),{type:'person',name:'Jamie Example'});it=practiceReduce(it,{type:'account',id:'person2',role:'hSHL'});assert.ok(it.completed);assert.equal(it.people[2].role,'hSHL');
});
test('practice transport rejects operational reads, mutations, functions and notifications',async()=>{
 const {setPracticeIsolation,isolatedFetch}=await import('../src/practiceIsolation.ts');const original=globalThis.fetch;const calls=[];globalThis.fetch=async(input)=>{calls.push(input);return new Response('{}')};try{setPracticeIsolation(true);for(const path of ['/rest/v1/rpc/scheduler_action','/rest/v1/rpc/scheduler_read','/functions/v1/manage-accounts','/rest/v1/staff','/rest/v1/rpc/shift_preset_save'])await assert.rejects(isolatedFetch('https://example.supabase.co'+path,{method:'POST',body:'{}'}),/disabled while practice/);assert.equal(calls.length,0);await isolatedFetch('https://example.supabase.co/rest/v1/rpc/onboarding_save',{method:'POST'});assert.equal(calls.length,1);setPracticeIsolation(false);await isolatedFetch('https://example.supabase.co/rest/v1/rpc/scheduler_read');assert.equal(calls.length,2)}finally{setPracticeIsolation(false);globalThis.fetch=original}
});
