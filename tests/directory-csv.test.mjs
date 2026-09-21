import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,uid} from './scheduler-fixture.mjs';
test('directory CSV is restricted to GM/IT, spans pages, and excludes unrelated private information',async()=>{
 const {db,as}=await fixture();try{
 await assert.rejects(as(4,'select directory_csv_export()'),/GM or IT/);
 await assert.rejects(as(3,'select directory_csv_export()'),/GM or IT/);
 await assert.rejects(as(2,'select directory_csv_export()'),/GM or IT/);
 await db.query('update manager_profiles set is_gm=true where id=$1',[uid(2)]);
 await db.exec("insert into private.person_contacts(person_id,phone,email,emergency_name,emergency_phone) values('s:Casey.W','555-0100','casey@example.test','PRIVATE EMERGENCY','555-0199')");
 await db.exec("insert into staff(first_name,last_name,department) select 'Example'||n,'Person','FOH' from generate_series(1,55) n");
 const get=async n=>(await as(n,'select directory_csv_export() r')).rows[0].r;
 const gm=await get(2),it=await get(1);assert.equal(gm.length,59);assert.deepEqual(gm,it);
 assert.equal(gm.find(p=>p.person_id==='s:Casey.W').phone,'555-0100');
 assert.equal(gm.find(p=>p.person_id==='s:Casey.W').version,1);
 assert.ok(!JSON.stringify(gm).includes('PRIVATE EMERGENCY'));assert.ok(!JSON.stringify(gm).includes('hourly_rate'));
 }finally{await db.close()}
});
