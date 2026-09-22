import {test} from 'node:test';
import assert from 'node:assert/strict';
import {trainingProgress,trainingBadge} from '../src/trainingProgress.ts';
test('training progress counts distinct completed Central-time shifts separately for each position and employee',()=>{
 const position={id:'cashier',name:'Cashier',target_shifts:4,active:true};
 const shift=(date,number=1,extra={})=>({staff_id:'A',training_position_id:'cashier',scheduled_at:date,status:'Completed',shift:number,...extra});
 const rows=[shift('2026-09-21T17:00:00Z'),shift('2026-09-21T18:00:00Z'),shift('2026-09-21T22:00:00Z',2),shift('2026-09-22T00:00:00Z',2),shift('2026-09-22T17:00:00Z',1,{status:'Scheduled'}),shift('2026-09-23T17:00:00Z',1,{status:'Missed'}),shift('2026-09-24T17:00:00Z',1,{status:'Cancelled'}),shift('2026-09-25T17:00:00Z',1,{training_position_id:'prep'}),shift('2026-09-26T17:00:00Z',1,{staff_id:'B'}),shift('2026-09-27T17:00:00Z',1,{training_position_id:null})];
 assert.deepEqual(trainingProgress('A',position,rows),{completed:2,target:4,remaining:2,scheduled:1,started:true});
 rows.push(shift('2026-09-22T17:00:00Z'),shift('2026-09-23T17:00:00Z'));
 assert.equal(trainingProgress('A',position,rows).remaining,0);
 assert.equal(trainingProgress('A',{...position,target_shifts:5},rows).remaining,1);
 assert.equal(trainingProgress('C',position,rows).started,false);
});
test('active qualifications fill progress to the job target without inventing sessions; revocation restores recorded progress',()=>{
 const job={id:'gsr',name:'GSR',target_shifts:4,active:true};
 const rows=[{staff_id:'A',training_position_id:'gsr',scheduled_at:'2026-09-21T17:00:00Z',status:'Completed',shift:1}];
 const qualified={id:'q',staff_id:'A',training_position_id:'gsr',active:true,origin:'experience',created_by:'manager',created_at:'2026-09-21',version:1};
 for(const origin of ['experience','migration','training']){const progress=trainingProgress('A',job,rows,[{...qualified,origin}]);assert.equal(progress.completed,4);assert.equal(progress.remaining,0)}
 assert.equal(rows.length,1);
 assert.equal(trainingProgress('A',job,rows,[{...qualified,active:false}]).completed,1);
 assert.equal(trainingProgress('B',job,rows,[qualified]).completed,0);
 assert.equal(trainingProgress('A',{...job,id:'expo'},rows,[qualified]).completed,0);
 assert.equal(trainingProgress('A',{...job,target_shifts:6},rows,[qualified]).completed,6);
});

test('directory badges show unstarted, scheduled, completed and revoked qualification states independently',()=>{
 const job={id:'gsr',name:'GSR',target_shifts:4,active:true};
 const session={staff_id:'A',training_position_id:'gsr',scheduled_at:'2026-09-21T17:00:00Z',status:'Scheduled',shift:1};
 const signed={id:'q',staff_id:'A',training_position_id:'gsr',active:true,version:1};
 assert.deepEqual(trainingBadge('A',job,[],[]),{color:'red',text:'GSR: 0/4 Shifts'});
 assert.deepEqual(trainingBadge('A',job,[session],[]),{color:'blue',text:'GSR: 0/4 Shifts'});
 assert.deepEqual(trainingBadge('A',job,[{...session,status:'Completed'}],[]),{color:'blue',text:'GSR: 1/4 Shifts'});
 assert.deepEqual(trainingBadge('A',job,[],[signed]),{color:'teal',text:'GSR: Trained'});
 assert.deepEqual(trainingBadge('A',job,[{...session,status:'Cancelled'}],[{...signed,active:false}]),{color:'red',text:'GSR: 0/4 Shifts'});
 assert.deepEqual(trainingBadge('B',job,[session],[signed]),{color:'red',text:'GSR: 0/4 Shifts'});
});
