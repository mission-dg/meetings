import {test} from 'node:test';
import assert from 'node:assert/strict';
import {managementPerson} from '../src/officePeople.ts';
const p={id:'s:one',staff_id:'one',active:true,on_roster:true,group:'FOH'};
const data={jobs:[{id:'ta',name:'TA',active:true},{id:'h',name:'hSHL',active:true},{id:'g',name:'GSR',active:true}],signoffs:[],meeting_managers:[]};
test('management picker excludes ordinary jobs and includes SHL, CA, TA and linked managers',()=>{
 assert.equal(managementPerson(p,data),false);
 for(const person of [{...p,group:'SHL'},{...p,is_ca:true},{...p,primary_job_id:'ta'}])assert.equal(managementPerson(person,data),true);
 assert.equal(managementPerson(p,{...data,meeting_managers:[{person_id:p.id}]}),true);
 assert.equal(managementPerson(p,{...data,signoffs:[{staff_id:'one',training_position_id:'h',active:true}]}),true);
 assert.equal(managementPerson(p,{...data,signoffs:[{staff_id:'one',training_position_id:'h',active:false}]}),false);
 assert.equal(managementPerson({...p,group:'SHL',active:false},data),false);
 assert.equal(managementPerson({...p,group:'SHL',on_roster:false},data),false);
});
