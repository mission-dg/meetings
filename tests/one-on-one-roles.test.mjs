import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture,uid} from './scheduler-fixture.mjs';
test('only salaried hosts can lead 1:1s; hourly recipients remain eligible and history is preserved',async()=>{
 const {db,as,read}=await fixture();try{
 await db.exec(`update manager_profiles set employment_type='Salaried' where id='${uid(2)}';update manager_profiles set employment_type='Hourly' where id='${uid(1)}'`);
 await db.exec(await readFile(new URL('../supabase/migrations/034_one_on_one_roles.sql',import.meta.url),'utf8'));
 assert.deepEqual((await read(1)).meeting_managers.map(m=>m.id),[uid(2)]);
 const insert=(staff,host)=>as(1,"insert into meetings(staff_id,manager_id,type,scheduled_at) values($1,$2,'Routine','2030-09-02T18:00:00Z') returning id",[staff,uid(host)]);
 await assert.rejects(insert('Casey.W',1),/active sSHL/);
 await db.exec("update staff set department='SHL' where id='Casey.W'");
 const m=(await insert('Casey.W',2)).rows[0];
 await as(1,"update meetings set status='Cancelled' where id=$1",[m.id]);
 await db.exec(`update manager_profiles set linked_staff_id='Jordan.D' where id='${uid(2)}'`);
 await assert.rejects(insert('Jordan.D',2),/non-sSHL/);
 assert.equal((await db.query('select status from meetings where id=$1',[m.id])).rows[0].status,'Cancelled');
 }finally{await db.close()}
});
