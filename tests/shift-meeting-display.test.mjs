import {test} from 'node:test';
import assert from 'node:assert/strict';
import {shiftMeetingNotes} from '../src/shiftMeetingDisplay.ts';
const employee={id:'work',person_id:'s:employee'},manager={id:'office',person_id:'m:manager'};
const meeting={id:'meeting',staff_id:'employee',work_shift_id:'work',manager_shift_id:'office',manager:'Manager',employee:'Teammate',timing_mode:'during_shift',status:'Scheduled',schedule_revision_id:'older-release'};
const data={self:{is_manager:true,person_id:'m:manager'},week:{draft:null},published:[{revision_id:'new-release',shifts:[employee,manager]}],shift_meetings:[meeting]};
test('linked 1:1 survives a subsequent release and labels both participants',()=>{
 assert.match(shiftMeetingNotes(data,employee)[0].text,/1:1 scheduled with Manager/);
 assert.match(shiftMeetingNotes(data,manager)[0].text,/with Teammate/);
});
test('employee projection only shows own published booking',()=>{
 const d={...data,self:{is_manager:false,person_id:'s:employee'}};
 assert.equal(shiftMeetingNotes(d,employee).length,1);
 assert.equal(shiftMeetingNotes(d,manager).length,0);
 assert.equal(shiftMeetingNotes({...d,self:{is_manager:false,person_id:'s:other'}},employee).length,0);
 assert.equal(shiftMeetingNotes({...d,published:[]},employee).length,0);
});
test('draft booking stays on draft cards only',()=>{
 const draftShift={...employee};const d={...data,week:{draft:{id:'draft',shifts:[draftShift]}},shift_meetings:[{...meeting,schedule_revision_id:'draft'}]};
 assert.equal(shiftMeetingNotes(d,employee).length,0);
 assert.equal(shiftMeetingNotes(d,draftShift).length,1);
 assert.equal(shiftMeetingNotes({...d,self:{is_manager:false,person_id:'s:employee'}},draftShift).length,0);
});
test('completion remains visible; cancellation and unlinked exact meetings do not appear',()=>{
 assert.match(shiftMeetingNotes({...data,shift_meetings:[{...meeting,status:'Completed'}]},employee)[0].text,/✓ 1:1 completed/);
 for(const change of [{status:'Cancelled'},{timing_mode:'exact'},{work_shift_id:'other'}])assert.equal(shiftMeetingNotes({...data,shift_meetings:[{...meeting,...change}]},employee).length,0);
});
