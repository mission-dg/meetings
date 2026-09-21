import {PGlite} from '@electric-sql/pglite';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,uid,sid} from './scheduler-fixture.mjs';
test('scheduler: private drafts, scheduled locking, permission boundaries, release, retry and stale publication protection',async()=>{
 const {db,as,act,read,shift}=await fixture();try{
 await assert.rejects(read(6),/access/);
 assert.equal((await read(4)).self.is_manager,false);
 assert.equal((await as(4,'select * from staff')).rows.length,0);
 await assert.rejects(as(4,'select * from private.schedule_revisions'),/permission denied/);
 await assert.rejects(act(3,'draft',{week:'2030-09-01'}),/Manager/);
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;
 await act(1,'save',{id:d.id,version:d.version,shifts:[shift(1)]});
 assert.equal((await read(4)).week.draft,null);assert.equal((await read(4)).published.length,0);
 await assert.rejects(act(1,'save',{id:d.id,version:d.version,shifts:[]}),/changed/);
 d=(await read(1)).week.draft;
 await act(1,'queue',{id:d.id,version:d.version,release_at:'2030-09-01T20:00:00Z'});
 d=(await read(1)).week.draft;
 await assert.rejects(act(1,'save',{id:d.id,version:d.version,shifts:[]}),/Cancel/);
 await as(4,'select scheduler_read($1)',['2030-09-01']);
 await db.exec(`update private.schedule_revisions set release_at=now()-interval '1 minute';select private.run_schedule_releases();select private.run_schedule_releases();`);
 const employee=await read(4);assert.equal(employee.published.length,1);assert.equal(employee.published[0].shifts[0].qualification_reason,undefined);assert.equal(employee.notifications.length,1);
 await assert.rejects(act(4,'announcement',{title:'No',body:'No',groups:[]}),/Manager or CA/);
 await act(3,'announcement',{title:'Training update',body:'Please check your upcoming training.',groups:['FOH']});assert.equal((await read(4)).announcements.length,1);assert.equal((await read(5)).announcements.length,0);
 const announcement=(await read(4)).announcements[0];await act(4,'read',{announcement_id:announcement.id});assert.equal((await read(4)).announcements[0].read,true);
 await act(3,'announcement',{id:announcement.id,version:announcement.version,title:announcement.title,body:'Updated training information.',groups:['FOH']});assert.equal((await read(4)).announcements[0].read,false);
 await assert.rejects(act(2,'announcement',{id:announcement.id,version:2,title:'Other',body:'Other',groups:[]}),/author/);
 await act(1,'draft',{week:'2030-09-01'});d=(await read(1)).week.draft;
 await act(1,'queue',{id:d.id,version:d.version,release_at:'2030-09-01T20:00:00Z'});
 await db.exec(`update private.schedule_weeks set published_id=null;update private.schedule_revisions set release_at=now()-interval '1 minute' where state='Queued';select private.run_schedule_releases();`);
 assert.equal((await read(1)).week.draft.state,'Attention');
 await db.exec("update staff set active=false where id='Casey.W'");await assert.rejects(read(4),/access/);
 }finally{await db.close()}
});
test('scheduler requests: approvals, conflicts, private reasons, open offers and atomic cross-week swaps',async()=>{
 const {db,as,act,read,shift}=await fixture();try{
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;
 await act(1,'save',{id:d.id,version:d.version,shifts:[shift(1),shift(2,'s:Alex.L','2030-09-03T16:00:00Z','2030-09-03T21:00:00Z')]});d=(await read(1)).week.draft;await act(1,'release',{id:d.id,version:d.version});
 await act(4,'request',{kind:'Time off',details:{category:'RTO',start:'2030-09-02T00:00:00Z',end:'2030-09-03T00:00:00Z'},reason:'Private reason'});let q=(await read(4)).requests[0];
 await assert.rejects(act(2,'decide',{id:q.id,version:q.version,decision:'Approved'}),/Resolve conflicting/);
 assert.equal((await read(4)).requests[0].status,'Pending');assert.equal((await read(3)).requests.length,0);
 await act(2,'decide',{id:q.id,version:q.version,decision:'Rejected'});
 await act(4,'request',{kind:'Availability',details:{effective:'2030-09-01',days:Array.from({length:7},()=>[[0,1440]])}});q=(await read(4)).requests.find(x=>x.kind==='Availability');await act(2,'decide',{id:q.id,version:q.version,decision:'Approved'});
 await act(4,'request',{kind:'Offer',source_id:shift(1).id,reason:'Private coverage reason'});q=(await read(4)).requests.find(x=>x.kind==='Offer');assert.equal((await read(3)).requests.find(x=>x.id===q.id).reason,undefined);
 await act(3,'accept',{id:q.id,version:q.version});await assert.rejects(act(5,'accept',{id:q.id,version:q.version}),/changed/);
 q=(await read(1)).requests.find(x=>x.id===q.id);
 await act(2,'decide',{id:q.id,version:q.version,decision:'Approved',qualification_reason:'Coverage while building experience'});
 assert.equal((await read(4)).published[0].shifts.find(s=>s.id===shift(1).id).person_id,'s:Alex.L');
 await act(3,'request',{kind:'Trade',source_id:shift(1).id,target_id:shift(2).id}).then(()=>assert.fail('cannot trade with self'),e=>assert.match(e.message,/another eligible/));
 // An approved unavailable day blocks later release, while pending availability does not.
 const days=Array.from({length:7},()=>[[0,1440]]);days[4]=[];
 await act(4,'request',{kind:'Availability',details:{effective:'2030-09-02',days}});q=(await read(4)).requests.find(x=>x.kind==='Availability'&&x.status==='Pending');await act(2,'decide',{id:q.id,version:q.version,decision:'Approved'});
 await act(1,'draft',{week:'2030-09-01'});d=(await read(1)).week.draft;
 await act(1,'save',{id:d.id,version:d.version,shifts:[shift(3,'s:Casey.W','2030-09-05T16:00:00Z','2030-09-05T21:00:00Z')]});d=(await read(1)).week.draft;
 await assert.rejects(act(1,'release',{id:d.id,version:d.version}),/availability/);
 }finally{await db.close()}
});
test('linked training: CA/published-only creation, creator editing, participants, locking, and legacy retention',async()=>{
 const {db,as,act,read,shift,gsr}=await fixture();try{
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;
 await act(1,'save',{id:d.id,version:d.version,shifts:[shift(1),shift(2,'s:Alex.L')]});d=(await read(1)).week.draft;
 const insert=(who,revision)=>as(who,"insert into training_sessions(staff_id,trainer_id,training_position_id,shift,scheduled_at,ends_at,work_shift_id,trainer_shift_id,schedule_revision_id) values('Casey.W','Alex.L',$1,1,'2030-09-02T17:00:00Z','2030-09-02T18:00:00Z',$2,$3,$4) returning id",[gsr,shift(1).id,shift(2).id,revision]);
 await assert.rejects(insert(3,d.id),/published/);
 const tid=(await insert(1,d.id)).rows[0].id;d=(await read(1)).week.draft;
 assert.equal((await read(4)).training.length,0);assert.equal((await read(3)).training.length,0);
 await act(1,'queue',{id:d.id,version:d.version,release_at:'2030-09-01T12:00:00Z'});
 await assert.rejects(as(1,"update training_sessions set status='Cancelled' where id=$1",[tid]),/queued/);
 d=(await read(1)).week.draft;await act(1,'unqueue',{id:d.id,version:d.version});d=(await read(1)).week.draft;await act(1,'release',{id:d.id,version:d.version});
 assert.equal((await read(4)).training.length,1);assert.equal((await read(5)).training.length,0);
 assert.equal((await as(3,"update training_sessions set status='Cancelled' where id=$1 returning id",[tid])).rows.length,0);
 await assert.rejects(insert(3,null),/already has training/);
 await as(1,"update training_sessions set status='Cancelled' where id=$1",[tid]);const own=(await insert(3,null)).rows[0].id;
 await assert.rejects(as(3,"update training_sessions set status='Completed' where id=$1",[own]),/future/);
 await as(3,"update training_sessions set status='Cancelled' where id=$1",[own]);
 await assert.rejects(as(4,"insert into training_sessions(staff_id,trainer_id,training_position_id,shift,scheduled_at,ends_at,work_shift_id,trainer_shift_id) values('Casey.W','Alex.L',$1,1,'2030-09-02T17:00:00Z','2030-09-02T18:00:00Z',$2,$3)",[gsr,shift(1).id,shift(2).id]),/row-level security/);
 await act(1,'draft',{week:'2030-09-01'});d=(await read(1)).week.draft;await act(1,'save',{id:d.id,version:d.version,shifts:[shift(1)]});d=(await read(1)).week.draft;await act(1,'release',{id:d.id,version:d.version});
 }finally{await db.close()}
});
test('scheduler invitations: managers may reserve employee-only invitations; verification and replay checks fail closed',async()=>{
 const {db,as,act,read}=await fixture();try{
 await as(1,"insert into staff(first_name,last_name,department) values('New','Invite','FOH')");
 await assert.rejects(as(2,'select reserve_employee_invitation($1,$2,$3)',['New.I','new@example.test',sid(900)]),/disabled/);
 await assert.rejects(act(2,'email_verified',{verified:true,evidence:'sender@example.test tested'}),/IT Admin/);
 await act(1,'email_verified',{verified:true,evidence:'sender@example.test: invitation and reset delivery verified in test fixture'});
 await assert.rejects(as(3,'select reserve_employee_invitation($1,$2,$3)',['New.I','new@example.test',sid(900)]),/Manager/);
 let result=await as(2,'select reserve_employee_invitation($1,$2,$3) r',['New.I','new@example.test',sid(900)]);assert.equal(result.rows[0].r.fresh,true);
 result=await as(2,'select reserve_employee_invitation($1,$2,$3) r',['New.I','new@example.test',sid(900)]);assert.equal(result.rows[0].r.fresh,false);
 await assert.rejects(as(2,'select reserve_employee_invitation($1,$2,$3)',['New.I','different@example.test',sid(900)]),/changed/);
 await assert.rejects(as(2,'select finish_employee_invitation($1,$2)',[sid(900),uid(6)]),/permission denied/);
 await db.query('select finish_employee_invitation($1,$2)',[sid(900),uid(6)]);
 assert.equal((await read(6)).self.is_manager,false);assert.equal((await read(6)).self.is_ca,false);
 await assert.rejects(act(2,'employee_access',{id:uid(6),version:1,active:true,is_ca:true}),/IT Admin/);
 await act(1,'employee_access',{id:uid(6),version:1,active:true,is_ca:true});assert.equal((await read(6)).self.is_ca,true);
 }finally{await db.close()}
});

test('scheduler: atomic cross-week trades, failed approval rollback, and stale queued drafts',async()=>{
 const {db,act,read,shift}=await fixture();try{
 const weeks=['2030-09-01','2030-09-08'];
 const originals=[shift(20),shift(21,'s:Alex.L','2030-09-09T16:00:00Z','2030-09-09T21:00:00Z')];
 for(let i=0;i<2;i++){await act(1,'draft',{week:weeks[i]});let d=(await read(1,weeks[i])).week.draft;await act(1,'save',{id:d.id,version:d.version,shifts:[originals[i]]});d=(await read(1,weeks[i])).week.draft;await act(1,'release',{id:d.id,version:d.version})}
 await act(1,'draft',{week:weeks[0]});let d=(await read(1)).week.draft;await act(1,'queue',{id:d.id,version:d.version,release_at:'2030-09-01T12:00:00Z'});
 await act(4,'request',{kind:'Trade',source_id:originals[0].id,target_id:originals[1].id});let q=(await read(4)).requests[0];await act(3,'accept',{id:q.id,version:q.version});q=(await read(1)).requests[0];
 await assert.rejects(act(2,'decide',{id:q.id,version:q.version,decision:'Approved'}),/sign-off/);
 assert.equal((await read(1)).published.find(w=>w.week===weeks[0]).shifts[0].person_id,'s:Casey.W');
 await act(2,'decide',{id:q.id,version:q.version,decision:'Approved',qualification_reason:'Supervised trade'});
 let r=await read(1);assert.equal(r.published.find(w=>w.week===weeks[0]).shifts[0].person_id,'s:Alex.L');assert.equal(r.published.find(w=>w.week===weeks[1]).shifts[0].person_id,'s:Casey.W');
 await db.exec("update private.schedule_revisions set release_at=now()-interval '1 minute' where state='Queued';select private.run_schedule_releases();");
 r=await read(1);assert.equal(r.week.draft.state,'Attention');assert.match(r.week.draft.error,/published schedule changed/);assert.equal(r.published.find(w=>w.week===weeks[0]).shifts[0].person_id,'s:Alex.L');
 }finally{await db.close()}
});

test('scheduler: malformed availability, submission replay, copy previous week, cancellation and expired offers',async()=>{
 const {db,act,read,shift}=await fixture();try{
 for(const days of [undefined,null,{},[[],[],[],[],[],[],[[null,100]]]])await assert.rejects(act(4,'request',{kind:'Availability',details:{effective:'2030-09-01',days}}),/weekdays|Availability|availability/);
 const sub=sid(800);const first=await act(1,'draft',{week:'2030-09-01'},sub);assert.deepEqual(await act(1,'draft',{week:'2030-09-01'},sub),first);await assert.rejects(act(1,'draft',{week:'2030-09-08'},sub),/Submission changed/);
 let d=(await read(1)).week.draft;await act(1,'save',{id:d.id,version:d.version,shifts:[shift(40)]});d=(await read(1)).week.draft;await act(1,'release',{id:d.id,version:d.version});
 await act(1,'draft',{week:'2030-09-08',copy_previous:true});d=(await read(1,'2030-09-08')).week.draft;assert.equal(d.shifts.length,1);assert.notEqual(d.shifts[0].id,shift(40).id);assert.equal(new Date(d.shifts[0].start).toISOString(),'2030-09-09T16:00:00.000Z');
 await act(1,'queue',{id:d.id,version:d.version,release_at:'2030-09-08T12:00:00Z'});d=(await read(1,'2030-09-08')).week.draft;const queuedVersion=d.version;await act(2,'unqueue',{id:d.id,version:queuedVersion});await assert.rejects(act(1,'release',{id:d.id,version:queuedVersion}),/changed/);await db.exec('select private.run_schedule_releases()');assert.equal((await read(1,'2030-09-08')).week.draft.state,'Draft');
 await act(4,'request',{kind:'Offer',source_id:shift(40).id});
 await db.exec("update private.schedule_revisions set shifts=jsonb_set(shifts,'{0,start}',to_jsonb(now()-interval '1 minute')) where state='Published';select private.run_schedule_releases();select private.run_schedule_releases();");
 const r=await read(4);assert.equal(r.requests[0].status,'Invalid');assert.equal(r.notifications.filter(n=>n.event_key.startsWith('invalid:')).length,1);
 }finally{await db.close()}
});

test('scheduler worker: delayed release and revoked releasing manager preserve publication',async()=>{
 const {db,act,read,shift}=await fixture();try{
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;await act(1,'save',{id:d.id,version:d.version,shifts:[shift(50)]});d=(await read(1)).week.draft;await act(1,'queue',{id:d.id,version:d.version,release_at:'2030-09-01T12:00:00Z'});
 await db.exec("update private.schedule_revisions set release_at=now()-interval '1 minute',shifts=jsonb_set(shifts,'{0,start}',to_jsonb(now()-interval '1 minute'));select private.run_schedule_releases();");
 let r=await read(1);assert.equal(r.week.draft.state,'Attention');assert.match(r.week.draft.error,/already started/);assert.equal(r.published.length,0);
 d=r.week.draft;await act(2,'save',{id:d.id,version:d.version,shifts:[shift(50)]});d=(await read(2)).week.draft;await act(2,'queue',{id:d.id,version:d.version,release_at:'2030-09-01T12:00:00Z'});
 await db.exec(`update manager_profiles set active=false where id='${uid(2)}';update private.schedule_revisions set release_at=now()-interval '1 minute' where state='Queued';select private.run_schedule_releases();`);
 r=await read(1);assert.equal(r.week.draft.state,'Attention');assert.match(r.week.draft.error,/manager no longer has access/);assert.equal(r.published.length,0);
 }finally{await db.close()}
});

test('scheduler upgrade: preserves legacy evidence and blocks employee/CA retrieval of manager-only records',async()=>{
 const {db,as,read}=await fixture(true);try{
 const employee=await read(4),ca=await read(3);
 assert.equal(employee.appointments[0].id,sid(990));assert.equal(employee.training[0].id,sid(991));assert.equal(employee.training[0].ends_at,null);assert.equal(employee.training[0].work_shift_id,null);
 assert.ok(!JSON.stringify(employee).includes('PRIVATE'));assert.ok(!JSON.stringify(ca).includes('PRIVATE'));
 for(const user of [3,4])for(const table of ['meeting_notes','meetings','gm_requests','change_history','staff'])assert.equal((await as(user,'select * from '+table)).rows.length,0);
 assert.equal((await as(1,'select * from meeting_notes')).rows[0].body,'PRIVATE manager-only evidence');
 await as(1,"update training_sessions set status='Missed' where id=$1",[sid(991)]);assert.equal((await read(4)).training[0].status,'Missed');
 }finally{await db.close()}
});

test('availability: pending/denied changes preserve approval, future effective dates and manager decisions are enforced',async()=>{
 const {db,as,act,read,shift}=await fixture();try{
 const all=()=>Array.from({length:7},()=>[[0,1440]]);
 const conflict=async(start,end)=>(await db.query("select private.person_conflict('s:Casey.W',$1,$2) reason",[start,end])).rows[0].reason;
 await act(4,'request',{kind:'Availability',details:{effective:'2030-09-01',days:all()},reason:'Private availability reason'});
 let q=(await read(4)).requests[0];
 await assert.rejects(act(4,'decide',{id:q.id,version:q.version,decision:'Approved'}),/Another manager/);
 await assert.rejects(act(3,'decide',{id:q.id,version:q.version,decision:'Approved'}),/Another manager/);
 await act(2,'decide',{id:q.id,version:q.version,decision:'Approved',response:'Confirmed'});
 q=(await read(4)).requests[0];assert.equal(q.decided_name,'Manager');assert.ok(q.decided_at);assert.equal(q.response,'Confirmed');
 assert.equal((await read(3)).requests.length,0);assert.equal((await read(5)).requests.length,0);
 const days=all();days[1]=[[660,840],[900,1260]];days[2]=[[660,840],[840,1260]];days[4]=[];
 await act(4,'request',{kind:'Availability',details:{effective:'2030-09-08',days}});
 q=(await read(4)).requests.find(r=>r.status==='Pending');
 assert.equal(await conflict('2030-09-12T16:00:00Z','2030-09-12T18:00:00Z'),null);
 await act(2,'decide',{id:q.id,version:q.version,decision:'Rejected'});
 assert.equal(await conflict('2030-09-12T16:00:00Z','2030-09-12T18:00:00Z'),null);
 await act(4,'request',{kind:'Availability',details:{effective:'2030-09-08',days}});q=(await read(4)).requests.find(r=>r.status==='Pending');
 await act(2,'decide',{id:q.id,version:q.version,decision:'Approved'});
 assert.equal(await conflict('2030-09-05T16:00:00Z','2030-09-05T18:00:00Z'),null,'future approval does not change an earlier week');
 assert.match(await conflict('2030-09-12T16:00:00Z','2030-09-12T18:00:00Z'),/availability/);
 assert.equal(await conflict('2030-09-09T16:00:00Z','2030-09-09T19:00:00Z'),null);
 assert.match(await conflict('2030-09-09T18:00:00Z','2030-09-09T21:00:00Z'),/availability/,'a shift cannot cross an unavailable gap');
 assert.equal(await conflict('2030-09-10T18:00:00Z','2030-09-10T21:00:00Z'),null,'adjacent windows cover a continuous shift');
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;
 await act(1,'save',{id:d.id,version:d.version,shifts:[shift(71)]});d=(await read(1)).week.draft;await act(1,'release',{id:d.id,version:d.version});
 const none=all();none[1]=[];
 await act(4,'request',{kind:'Availability',details:{effective:'2030-09-01',days:none}});q=(await read(4)).requests.find(r=>r.status==='Pending');
 await assert.rejects(act(2,'decide',{id:q.id,version:q.version,decision:'Approved'}),/Resolve conflicting published/);
 assert.equal((await read(4)).requests.find(r=>r.id===q.id).status,'Pending');
 assert.equal((await read(4)).requests.find(r=>r.id===q.id).decided_at,null);
 await act(4,'withdraw',{id:q.id,version:q.version});assert.equal((await read(4)).requests.find(r=>r.id===q.id).status,'Withdrawn');
 await act(2,'request',{kind:'Availability',details:{effective:'2030-09-01',days:all()}});q=(await read(2)).requests.find(r=>r.created_by===uid(2));
 await assert.rejects(act(2,'decide',{id:q.id,version:q.version,decision:'Approved'}),/Another manager/);
 await act(1,'decide',{id:q.id,version:q.version,decision:'Approved'});assert.equal((await read(2)).requests.find(r=>r.id===q.id).decided_name,'Admin');
 }finally{await db.close()}
});
