import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,uid,sid} from './scheduler-fixture.mjs';
test('workspaces: server authorization, safe employee projection for admins and deactivation',async()=>{
 const {db,as,act,read,shift}=await fixture(true);try{
 const ws=async(n,v)=>(await as(n,'select workspace_read($1,$2) r',['2030-09-01',v])).rows[0].r;
 assert.deepEqual((await as(1,'select workspace_session() r')).rows[0].r.views,['it','manager','employee']);
 assert.deepEqual((await as(2,'select workspace_session() r')).rows[0].r.views,['manager','employee']);
 for(const n of [3,4])for(const v of ['it','manager'])await assert.rejects(ws(n,v),/not available/);
 await assert.rejects(ws(2,'it'),/not available/);
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;
 await act(1,'save',{id:d.id,version:d.version,shifts:[shift(1)]});d=(await read(1)).week.draft;await act(1,'release',{id:d.id,version:d.version});await act(1,'draft',{week:'2030-09-01'});
 await act(4,'request',{kind:'Availability',details:{effective:'2030-09-01',days:Array.from({length:7},()=>[[0,1440]])},reason:'PRIVATE availability'});
 const employee=await ws(1,'employee');assert.equal(employee.self.id,uid(1));assert.equal(employee.self.is_manager,false);assert.equal(employee.self.is_admin,false);assert.equal(employee.week.draft,null);assert.deepEqual(employee.audit,[]);assert.deepEqual(employee.accounts,[]);assert.deepEqual(employee.service,{});assert.equal(employee.training.length,0);assert.equal(employee.requests.length,0);assert.equal(employee.published[0].shifts[0].qualification_reason,undefined);assert.ok(!JSON.stringify(employee).includes('PRIVATE'));
 assert.ok((await ws(1,'manager')).week.draft);assert.ok((await ws(3,'employee')).self.is_ca);
 await db.exec(`update manager_profiles set is_admin=false where id='${uid(1)}'`);await assert.rejects(ws(1,'it'),/not available/);
 await db.exec(`update private.employee_accounts set active=false where id='${uid(4)}'`);await assert.rejects(ws(4,'employee'),/access/);
 }finally{await db.close()}
});
test('temporary availability: inclusive expiry, baseline restoration, explicit replacement and atomic conflict rollback',async()=>{
 const {db,act,read}=await fixture();try{
 const all=()=>Array.from({length:7},()=>[[0,1440]]);
 const submit=async(details)=>{await act(4,'request',{kind:'Availability',details});return (await read(4)).requests.find(q=>q.status==='Pending')};
 const approve=async(q,extra={})=>act(2,'decide',{id:q.id,version:q.version,decision:'Approved',...extra});
 const conflict=async(day)=>(await db.query("select private.person_conflict('s:Casey.W',$1,$2) r",[day+'T16:00:00Z',day+'T18:00:00Z'])).rows[0].r;
 await approve(await submit({effective:'2030-09-01',days:all()}));
 const q=await submit({effective:'2030-09-08',until:'2030-09-12',days:Array.from({length:7},()=>[])});await approve(q);
 assert.equal(await conflict('2030-09-07'),null);assert.match(await conflict('2030-09-12'),/availability/);assert.equal(await conflict('2030-09-13'),null);
 await assert.rejects(submit({effective:'2030-09-08',until:'2030-09-07',days:all()}),/end date/);
 const newer=await submit({effective:'2030-09-10',until:'2030-09-15',days:all()});await assert.rejects(approve(newer),/overlaps/);
 assert.equal((await read(4)).requests.find(x=>x.id===newer.id).status,'Pending');
 await assert.rejects(approve(newer,{replace_id:q.id,replace_version:1}),/changed/);
 await approve(newer,{replace_id:q.id,replace_version:2});assert.equal((await read(4)).requests.find(x=>x.id===q.id).status,'Withdrawn');assert.equal(await conflict('2030-09-12'),null);
 }finally{await db.close()}
});
test('PTO and RTO: hours validation, private reasons, queued attention, cancellation approval and idempotence',async()=>{
 const {db,act,read,shift}=await fixture();try{
 const details={start:'2030-09-02T16:00:00Z',end:'2030-09-02T21:00:00Z',category:'PTO',paid_hours:5};
 for(const invalid of [{...details,paid_hours:0},{...details,paid_hours:6},{...details,category:'RTO',paid_hours:1},{...details,category:null}])await assert.rejects(act(4,'request',{kind:'Time off',details:invalid}),/paid hours|PTO or RTO/i);
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;await act(1,'save',{id:d.id,version:d.version,shifts:[shift(8)]});d=(await read(1)).week.draft;await act(1,'queue',{id:d.id,version:d.version,release_at:'2030-09-01T12:00:00Z'});
 await act(4,'request',{kind:'Time off',details,reason:'PRIVATE medical reason'});let q=(await read(4)).requests[0];await act(2,'decide',{id:q.id,version:q.version,decision:'Approved'});
 assert.equal((await read(1)).week.draft.state,'Attention');assert.match((await read(1)).week.draft.error,/time off/);assert.equal((await read(3)).requests.length,0);
 q=(await read(4)).requests.find(x=>x.id===q.id);await assert.rejects(act(4,'withdraw',{id:q.id,version:q.version}),/no longer pending/);
 const sub=sid(900);const result=await act(4,'cancel_time_off',{id:q.id,version:q.version},sub);assert.deepEqual(await act(4,'cancel_time_off',{id:q.id,version:q.version},sub),result);
 assert.equal((await read(4)).requests.find(x=>x.id===q.id).status,'Approved');let c=(await read(4)).requests.find(x=>x.kind==='Cancel time off');
 await assert.rejects(act(4,'decide',{id:c.id,version:c.version,decision:'Approved'}),/Another manager/);
 await act(2,'decide',{id:c.id,version:c.version,decision:'Rejected'});assert.equal((await read(4)).requests.find(x=>x.id===q.id).status,'Approved');
 await act(4,'cancel_time_off',{id:q.id,version:q.version});c=(await read(4)).requests.find(x=>x.kind==='Cancel time off'&&x.status==='Pending');await act(2,'decide',{id:c.id,version:c.version,decision:'Approved'});
 assert.equal((await read(4)).requests.find(x=>x.id===q.id).status,'Withdrawn');assert.equal((await read(4)).requests.filter(x=>x.kind==='Cancel time off').length,2);
 }finally{await db.close()}
});
test('linked account roles: IT-only promotion, stable person IDs, one roster entry and safe demotion',async()=>{
 const {db,as,read,act,shift}=await fixture();try{
 const change=async(actor,id,role,version,managerVersion)=>(await as(actor,'select set_employee_role($1,$2,$3,$4,$5)',[uid(id),role,version,managerVersion,crypto.randomUUID()]));
 await assert.rejects(change(2,4,'manager',1,0),/IT Admin/);
 await change(1,4,'manager',1,0);let d=await read(4);assert.equal(d.self.person_id,'s:Casey.W');assert.equal(d.self.is_manager,true);assert.equal(d.people.filter(p=>p.staff_id==='Casey.W'||p.id==='m:'+uid(4)).length,1);assert.equal(d.people.find(p=>p.staff_id==='Casey.W').group,'SHL');
 assert.equal((await db.query("select private.shift_issues($1,'2030-09-01') i",[JSON.stringify([{...shift(80),job_id:null}])])).rows[0].i.length,0);
 await act(1,'draft',{week:'2030-09-01'});let draft=(await read(1)).week.draft;
 await act(1,'save',{id:draft.id,version:draft.version,shifts:[{...shift(80),job_id:null}]});draft=(await read(1)).week.draft;await act(1,'release',{id:draft.id,version:draft.version});
 await assert.rejects(act(4,'request',{kind:'Coverage',source_id:shift(80).id,recipient:'s:Jordan.D'}),/eligible/);
 await act(4,'request',{kind:'Coverage',source_id:shift(80).id,recipient:'m:'+uid(2)});let cover=(await read(4)).requests.find(q=>q.kind==='Coverage');
 const ownNotifications=(await as(2,'select workspace_read($1,$2) r',['2030-09-01','employee'])).rows[0].r.notifications;
 assert.ok(ownNotifications.some(n=>n.event_key==='request:'+cover.id),'personal coverage activity remains visible in Employee View');
 await act(2,'accept',{id:cover.id,version:cover.version});cover=(await read(1)).requests.find(q=>q.id===cover.id);await act(1,'decide',{id:cover.id,version:cover.version,decision:'Approved'});
 assert.equal((await read(1)).published[0].shifts[0].person_id,'m:'+uid(2),'linked and legacy SHLs can cover one another');
 await assert.rejects(change(1,4,'it',1,1),/changed/);
 await change(1,4,'it',2,1);d=await read(4);assert.equal(d.self.is_admin,true);assert.equal(d.self.person_id,'s:Casey.W');
 await change(1,4,'employee',3,2);d=await read(4);assert.equal(d.self.is_manager,false);assert.equal(d.self.person_id,'s:Casey.W');assert.equal(d.people.find(p=>p.staff_id==='Casey.W').group,'FOH');
 await change(1,4,'manager',4,3);await as(1,"update staff set first_name='Case' where id='Casey.W'");assert.equal((await read(4)).self.name,'Case Williams');
 const account=(await read(1)).accounts.find(a=>a.id===uid(4));await act(1,'employee_access',{id:account.id,version:account.version,active:false,is_ca:false});await assert.rejects(read(4),/access/);
 }finally{await db.close()}
});
