import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mealPeriod,assignmentGroup,visibleAssignments,sortedAssignments,absencesOnDay} from '../src/scheduleDisplay.ts';
import {centralInstant,hourlyShifts,hours} from '../src/scheduler.ts';
const shift=(a,b,day='2026-09-21')=>({id:a,person_id:'p',job_id:'gsr',slot:1,start:centralInstant(day+'T'+a),end:centralInstant(day+'T'+b)});
test('meal grouping: inclusive 2pm, 4pm boundary, strict majority and DST',()=>{
 for(const [a,b,expected] of [['12:00','20:00','Lunch'],['12:00','20:01','Dinner'],['14:00','18:00','Dinner'],['13:59','17:00','Lunch'],['08:00','16:00','Lunch'],['16:00','22:00','Dinner']])assert.equal(mealPeriod(shift(a,b)),expected);
 for(const day of ['2026-03-08','2026-11-01'])assert.equal(mealPeriod(shift('12:00','20:00',day)),'Lunch');
 assert.equal(mealPeriod({...shift('22:00','23:00'),end:centralInstant('2026-09-22T06:00')}),'Dinner');
});
test('assigned jobs drive groups; office is SHL; multiple cards retained; hourly time counted once',()=>{
 const jobs=[{id:'gsr',department:'FOH'},{id:'prep',department:'BOH'}];const a=shift('10:00','14:00'),b={...shift('15:00','20:00'),job_id:'prep'},office={...shift('20:00','21:00'),assignment_type:'closing_office'};
 assert.equal(assignmentGroup(a,jobs),'FOH');assert.equal(assignmentGroup(office,jobs),'SHL');assert.equal(assignmentGroup({...a,job_id:null},jobs),'SHL');assert.deepEqual(visibleAssignments([a,b,office],jobs,'BOH',null),[b]);assert.equal(visibleAssignments([a,b],jobs,'','p').length,2);
 const people=[{id:'p',name:'A',employment_type:'Hourly'},{id:'salary',name:'Z',employment_type:'Salaried'}];const list=hourlyShifts([a,b,office,{...a,id:'salary',person_id:'salary'}],people);assert.equal(hours(list),10);assert.deepEqual(sortedAssignments([b,a],people),[a,b]);
});
test('approved absences intersect a Central day, excluding midnight end and pending requests',()=>{
 const q={id:'1',kind:'Time off',status:'Approved',person_id:'unscheduled',payload:{start:centralInstant('2026-09-20T12:00'),end:centralInstant('2026-09-21T00:00')}};
 assert.equal(absencesOnDay([q],'2026-09-20').length,1);assert.equal(absencesOnDay([q],'2026-09-21').length,0);assert.equal(absencesOnDay([{...q,status:'Pending'}],'2026-09-20').length,0);
});
