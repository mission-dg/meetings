import {test} from 'node:test';
import assert from 'node:assert/strict';
import {centralInstant,localCandidates,weekOf,addDays,hours} from '../src/scheduler.ts';
import {approvedAvailability,upcomingAvailability,availabilityLabel,validateAvailability} from '../src/availability.ts';
test('availability view uses effective approved hours and preserves split time windows',()=>{
 const requests=[
  {id:'old',kind:'Availability',person_id:'s:Casey.W',status:'Approved',created_at:'2026-08-01T00:00:00Z',payload:{effective:'2026-08-01',days:[[[0,1440]]]}},
  {id:'future',kind:'Availability',person_id:'s:Casey.W',status:'Approved',created_at:'2026-08-02T00:00:00Z',payload:{effective:'2026-10-01',days:[[]]}},
  {id:'pending',kind:'Availability',person_id:'s:Casey.W',status:'Pending',created_at:'2026-09-01T00:00:00Z',payload:{effective:'2026-09-01',days:[[]]}},
 ];
 assert.equal(approvedAvailability(requests,'s:Casey.W','2026-09-21').id,'old');
 assert.equal(approvedAvailability(requests,'s:Casey.W','2026-10-01').id,'future');
 assert.equal(approvedAvailability(requests,'s:Alex.L','2026-10-01'),undefined);
 assert.deepEqual(upcomingAvailability(requests,'s:Casey.W','2026-09-21').map(q=>q.id),['future']);
 requests.push({...requests[0],id:'replacement',created_at:'2026-09-01T00:00:00Z'});
 assert.equal(approvedAvailability(requests,'s:Casey.W','2026-09-21').id,'replacement');
 assert.equal(availabilityLabel([[660,840],[900,1440]]),'11:00 AM – 2:00 PM, 3:00 PM – Midnight');
 assert.equal(availabilityLabel([]),'Unavailable');assert.equal(availabilityLabel([[0,1440]]),'All day');
 const days=Array.from({length:7},()=>[[660,840],[900,1440]]);assert.deepEqual(validateAvailability(days),days);
 for(const ranges of [[[840,660]],[[null,100]],[[660,900],[840,1440]]])assert.throws(()=>validateAvailability([ranges,...days.slice(1)]),/Sunday/);
});
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
