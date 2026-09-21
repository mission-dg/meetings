import {test} from 'node:test';
import assert from 'node:assert/strict';
import {qualificationWarnings} from '../src/scheduler.ts';
test('qualification warning requires both missing sign-off and missing valid trainer coverage',()=>{
 const s={id:'work',person_id:'s:Person',job_id:'gsr',start:'2030-09-02T16:00Z',end:'2030-09-02T20:00Z',slot:1};
 const trainer={...s,id:'trainer-work',person_id:'s:Trainer',job_id:null};
 const d={week:{start:'2030-09-01',draft:{id:'draft'}},published:[],people:[{id:'s:Person',staff_id:'Person',name:'Trainee'}, {id:'s:Trainer',staff_id:'Trainer',active:true,is_trainer:true}],jobs:[{id:'gsr',name:'GSR'}],signoffs:[],training:[]};
 assert.equal(qualificationWarnings(d,[s,trainer]).length,1);
 d.signoffs=[{staff_id:'Person',training_position_id:'gsr',active:true}];assert.equal(qualificationWarnings(d,[s,trainer]).length,0);d.signoffs=[];
 const t={status:'Scheduled',staff_id:'Person',trainer_id:'Trainer',training_position_id:'gsr',work_shift_id:'work',trainer_shift_id:'trainer-work',schedule_revision_id:'draft',scheduled_at:s.start,ends_at:s.end};d.training=[t];assert.equal(qualificationWarnings(d,[s,trainer]).length,0);
 for(const change of [{status:'Cancelled'},{training_position_id:'expo'},{ends_at:'2030-09-02T18:00Z'},{schedule_revision_id:'other-draft'}]){d.training=[{...t,...change}];assert.equal(qualificationWarnings(d,[s,trainer]).length,1)}
 d.training=[t];assert.equal(qualificationWarnings(d,[s]).length,1);
});
