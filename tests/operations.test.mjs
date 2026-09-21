import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,uid,sid} from './scheduler-fixture.mjs';
test('operations: contact consent, emergency privacy, logbook authorship and labor permissions',async()=>{
 const {db,as}=await fixture();try{
 let id=4000;const act=async(n,a,p)=>(await as(n,'select operations_action($1,$2,$3) r',[a,JSON.stringify(p),sid(id++)])).rows[0].r;
 const read=async(n,m,v='employee')=>(await as(n,'select operations_read($1,$2) r',[m,v])).rows[0].r;
 await act(4,'profile_save',{version:0,phone:'PRIVATE PHONE',email:'shared@example.test',share_email:true,emergency_name:'PRIVATE EMERGENCY',birthday_month:2,birthday_day:29});
 let directory=(await read(3,'directory')).items;let c=directory.find(p=>p.person_id==='s:Casey.W');assert.equal(c.phone,null);assert.equal(c.email,'shared@example.test');assert.equal(c.emergency_name,null);
 c=(await read(1,'directory')).items.find(p=>p.person_id==='s:Casey.W');assert.equal(c.phone,null);assert.equal(c.emergency_name,null,'admin employee view is safe');
 c=(await read(2,'directory','manager')).items.find(p=>p.person_id==='s:Casey.W');assert.equal(c.emergency_name,'PRIVATE EMERGENCY');
 await assert.rejects(act(4,'profile_save',{version:0}),/changed/);await assert.rejects(act(4,'profile_save',{version:1,birthday_month:2,birthday_day:30}),/range/);
 await assert.rejects(read(4,'labor','manager'),/access/);await assert.rejects(read(1,'labor'),/Manager workspace/);
 await assert.rejects(act(2,'rate_save',{person_id:'s:Casey.W',effective:'2030-09-01',hourly_rate:20,version:0}),/GM or IT/);
 await act(1,'rate_save',{person_id:'s:Casey.W',effective:'2030-09-01',hourly_rate:20,version:0});assert.equal((await read(2,'labor','manager')).rates.length,1);
 await assert.rejects(act(1,'rate_save',{person_id:'s:Casey.W',effective:'2030-09-01',hourly_rate:25,version:0}),/changed/);
 await act(2,'forecast_save',{day:'2030-09-01',amount:4000,version:0});
 await act(1,'logbook_save',{title:'Handover',body:'PRIVATE manager logbook',entry_date:'2030-09-01',assigned_to:uid(2)});let entry=(await read(2,'logbook','manager')).items[0];
 await assert.rejects(act(2,'logbook_save',{id:entry.id,version:entry.version,title:'Changed'}),/author/);
 await act(2,'logbook_complete',{id:entry.id,version:entry.version});assert.ok((await read(1,'logbook','it')).items[0].completed_at);
 await assert.rejects(read(3,'logbook'),/Manager workspace/);
 await as(1,`insert into meetings(staff_id,manager_id,type,scheduled_at) values('Casey.W','${uid(1)}','Routine',now()+interval '1 minute')`);
 assert.equal((await read(2,'brief','manager')).appointments.length,1,'daily brief includes other managers’ meetings');
 await assert.rejects(read(4,'brief','manager'),/access/);await assert.rejects(read(1,'brief','employee'),/Manager workspace/);
 }finally{await db.close()}
});
test('calendar: revocable token, publication-only contents, stable IDs and service-only API',async()=>{
 const {db,as,act,read,shift}=await fixture(true);try{
 const token=async n=>(await as(n,'select operations_action($1,$2,$3) r',['calendar_create','{}',crypto.randomUUID()])).rows[0].r.token;
 const get=async t=>(await db.query('select calendar_feed_data($1) r',[t])).rows[0].r;
 const t=await token(4);assert.match(t,/^[0-9a-f]{64}$/);await assert.rejects(as(4,'select calendar_feed_data($1)',[t]),/permission denied/);
 assert.equal(await get('bad'),null);assert.ok(!JSON.stringify(await get(t)).includes('PRIVATE'));
 await act(1,'draft',{week:'2030-09-01'});let d=(await read(1)).week.draft;await act(1,'save',{id:d.id,version:d.version,shifts:[shift(8,'s:Casey.W',new Date(Date.now()+86400000).toISOString(),new Date(Date.now()+86400000+3600000).toISOString())]});
 assert.equal((await get(t)).events.filter(e=>e.uid.startsWith('shift-')).length,0,'draft excluded');
 const next=await token(4);assert.equal(await get(t),null);assert.ok(await get(next));await db.exec(`update private.employee_accounts set active=false where id='${uid(4)}'`);assert.equal(await get(next),null);
 }finally{await db.close()}
});
test('documents: audiences, stale updates, version-specific read activity and private files',async()=>{
 const {db,as}=await fixture();try{
 let seq=7000;const act=async(n,a,p)=>(await as(n,'select operations_action($1,$2,$3) r',[a,JSON.stringify(p),sid(seq++)])).rows[0].r;
 const read=async(n,v='employee')=>(await as(n,'select operations_read($1,$2) r',['documents',v])).rows[0].r;
 await assert.rejects(act(3,'document_save',{title:'CA document',filename:'file.pdf',groups:[]}),/Manager/);
 const d=await act(1,'document_save',{title:'FOH guide',filename:'foh.pdf',groups:['FOH']});await db.query('update private.document_versions set ready=true where id=$1',[d.file_id]);
 assert.equal((await read(4)).items.length,1);assert.equal((await read(5)).items.length,0);assert.equal((await read(1)).items.length,0,'admin Employee View uses SHL audience');
 await act(4,'document_activity',{id:d.id,version:1,kind:'Downloaded'});assert.equal((await read(4)).items[0].read,false);
 await act(4,'document_activity',{id:d.id,version:1,kind:'Read'});assert.equal((await read(4)).items[0].read,true);
 await assert.rejects(act(5,'document_activity',{id:d.id,version:1,kind:'Read'}),/unavailable/);
 const newer=await act(2,'document_save',{id:d.id,version:1,title:'FOH guide',filename:'new.pdf',groups:['FOH']});await db.query('update private.document_versions set ready=true where id=$1',[newer.file_id]);assert.equal((await read(4)).items[0].read,false);
 await assert.rejects(act(4,'document_activity',{id:d.id,version:1,kind:'Read'}),/changed/);
 assert.equal((await read(2,'manager')).items[0].history.length,2);
 }finally{await db.close()}
});
test('private storage: uploads require manager ownership; employees cannot fetch another audience or old versions',async()=>{
 const {db,as}=await fixture();try{
 await db.exec("create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text,unique(bucket_id,name));alter table storage.objects enable row level security;grant usage on schema storage to authenticated;grant select,insert on storage.objects to authenticated;");
 const {readFile}=await import('node:fs/promises');await db.exec(await readFile(new URL('../supabase/migrations/013_document_storage.sql',import.meta.url),'utf8'));
 const d=(await as(1,'select operations_action($1,$2,$3) r',['document_save',JSON.stringify({title:'Private FOH',filename:'guide.pdf',groups:['FOH']}),sid(9991)])).rows[0].r;
 await assert.rejects(as(4,"insert into storage.objects(bucket_id,name) values('shift-documents',$1)",[d.path]),/row-level security/);
 await assert.rejects(as(2,"insert into storage.objects(bucket_id,name) values('shift-documents',$1)",[d.path]),/row-level security/);
 await assert.rejects(as(1,'select document_ready($1)',[d.file_id]),/not completed/);
 await as(1,"insert into storage.objects(bucket_id,name) values('shift-documents',$1)",[d.path]);await as(1,'select document_ready($1)',[d.file_id]);await as(1,'select document_ready($1)',[d.file_id]);
 assert.equal((await as(4,'select * from storage.objects')).rows.length,1);assert.equal((await as(5,'select * from storage.objects')).rows.length,0);
 await as(2,'select operations_action($1,$2,$3) r',['document_save',JSON.stringify({id:d.id,version:1,title:'Private FOH',filename:'guide.pdf',groups:['FOH'],archive:true}),sid(9992)]);
 assert.equal((await as(4,'select * from storage.objects')).rows.length,0);assert.equal((await as(1,'select * from storage.objects')).rows.length,1);
 }finally{await db.close()}
});
test('calendar tracks publication, cancellation and permanently revokes disabled accounts',async()=>{
 const {db,as,act,read,shift}=await fixture();try{
 const start=new Date(Date.now()+10*86400000);start.setUTCHours(17,0,0,0);const end=new Date(start.getTime()+3600000);const sunday=new Date(start);sunday.setUTCDate(start.getUTCDate()-start.getUTCDay());const week=sunday.toISOString().slice(0,10);
 const token=(await as(4,'select operations_action($1,$2,$3) r',['calendar_create','{}',sid(9980)])).rows[0].r.token;
 const get=async()=>(await db.query('select calendar_feed_data($1) r',[token])).rows[0].r;
 await act(1,'draft',{week});let d=(await read(1,week)).week.draft;await act(1,'save',{id:d.id,version:d.version,shifts:[shift(98,'s:Casey.W',start.toISOString(),end.toISOString())]});d=(await read(1,week)).week.draft;
 assert.equal((await get()).events.length,0);await act(1,'release',{id:d.id,version:d.version});let event=(await get()).events[0];assert.equal(event.uid,'shift-'+shift(98).id);assert.equal(event.status,'CONFIRMED');assert.ok(!JSON.stringify(event).includes('qualification'));
 await act(1,'draft',{week});d=(await read(1,week)).week.draft;await act(1,'save',{id:d.id,version:d.version,shifts:[]});d=(await read(1,week)).week.draft;await act(1,'release',{id:d.id,version:d.version});const removed=(await get()).events[0];assert.equal(removed.uid,event.uid);assert.equal(removed.status,'CANCELLED');assert.ok(removed.sequence>event.sequence);
 await db.exec(`update private.employee_accounts set active=false where id='${uid(4)}';update private.employee_accounts set active=true where id='${uid(4)}'`);assert.equal(await get(),null);
 }finally{await db.close()}
});
