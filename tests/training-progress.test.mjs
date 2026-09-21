import {test} from 'node:test';
import assert from 'node:assert/strict';
import {trainingProgress} from '../src/trainingProgress.ts';
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
