import {test} from 'node:test';
import assert from 'node:assert/strict';
import {centralInstant,localCandidates,weekOf,addDays,hours} from '../src/scheduler.ts';
test('scheduler local times reject DST gaps, require fold choice, preserve Sunday weeks and actual overnight hours',()=>{
 assert.equal(weekOf('2026-09-21'),'2026-09-20');assert.equal(weekOf('2026-09-20'),'2026-09-20');
 assert.equal(addDays('2026-12-31',1),'2027-01-01');
 assert.throws(()=>centralInstant('2026-03-08T02:30'),/does not exist/);
 assert.equal(localCandidates('2026-11-01T01:30').length,2);assert.throws(()=>centralInstant('2026-11-01T01:30'),/occurs twice/);
 assert.equal(centralInstant('2026-11-01T01:30','earlier'),'2026-11-01T06:30:00.000Z');assert.equal(centralInstant('2026-11-01T01:30','later'),'2026-11-01T07:30:00.000Z');
 assert.equal(hours([{start:centralInstant('2026-10-31T23:00'),end:centralInstant('2026-11-01T03:00')}]),5);
});

import {addMonths,labels,emptyData} from '../src/domain.ts';
test('six-month reminders remain based on completed meetings, including anniversary and month-end behavior',()=>{
 const employee={id:'Alex.L',active:true,priority:false};
 assert.equal(addMonths('2025-08-31',6),'2026-02-28');
 assert.deepEqual(labels(employee,emptyData,'2026-09-21'),{last:undefined,due:null,needs:true,priority:false,requested:false});
 const data={...emptyData,meetings:[{staff_id:'Alex.L',status:'Completed',completed_on:'2026-03-21'},{staff_id:'Alex.L',status:'Scheduled',completed_on:null}],training:[{staff_id:'Alex.L',status:'Completed',scheduled_at:'2026-09-20T18:00:00Z'}]};
 assert.equal(labels(employee,data,'2026-09-20').needs,false);assert.equal(labels(employee,data,'2026-09-21').needs,true);assert.equal(labels(employee,data,'2026-09-21').priority,false);assert.equal(labels(employee,data,'2026-09-22').priority,true);assert.equal(labels({...employee,active:false},data,'2026-09-22').needs,false);
});
