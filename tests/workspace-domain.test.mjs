import {test} from 'node:test';
import assert from 'node:assert/strict';
import {chooseWorkspace,allowedPage} from '../src/workspaces.ts';
import {approvedAvailability} from '../src/availability.ts';
import {laborRows,csvText} from '../src/labor.ts';
import {calendarText} from '../supabase/functions/calendar-feed/ical.ts';
test('workspace routing: defaults, retained authorized view and protected direct links',()=>{
 const admin={views:['it','manager','employee']};assert.equal(chooseWorkspace(admin,null),'it');assert.equal(chooseWorkspace(admin,'employee'),'employee');assert.equal(chooseWorkspace({views:['employee']},'it'),'employee');assert.equal(allowedPage('employee','accounts'),false);assert.equal(allowedPage('employee','labor'),false);assert.equal(allowedPage('employee','training'),true);assert.equal(allowedPage('manager','administration'),false);
});
test('availability UI matches inclusive temporary override and baseline restoration',()=>{
 const q=(id,effective,until)=>({id,kind:'Availability',person_id:'one',status:'Approved',payload:{effective,until}});
 const requests=[q('regular','2030-01-01'),q('temp','2030-03-01','2030-03-31'),q('newregular','2030-03-15')];
 assert.equal(approvedAvailability(requests,'one','2030-03-31').id,'temp');assert.equal(approvedAvailability(requests,'one','2030-04-01').id,'newregular');
});
test('labor uses effective rates, actual elapsed hours and explicit missing rates',()=>{
 const shifts=[{person_id:'one',start:'2030-09-02T16:00Z',end:'2030-09-02T21:00Z'},{person_id:'two',start:'2030-09-02T17:00Z',end:'2030-09-02T19:00Z'}];
 const rates=[{person_id:'one',effective:'2030-01-01',hourly_rate:20},{person_id:'one',effective:'2030-09-03',hourly_rate:25}];
 let row=laborRows(shifts,rates,[{day:'2030-09-02',amount:1000}])[0];assert.equal(row.cost,100);assert.equal(row.missing,1);assert.equal(row.percent,null);row=laborRows(shifts.slice(0,1),rates,[{day:'2030-09-02',amount:1000}])[0];assert.equal(row.percent,10);assert.equal(laborRows([{person_id:'one',start:'2030-09-02T16:00Z',end:'2030-09-02T16:01Z'}],rates,[])[0].cost,0.33);assert.match(csvText([['=HYPERLINK("evil")','Name']]),/"'=HYPERLINK/);
});
test('calendar escapes content and folds UTF-8 lines without fabricating end times',()=>{
 const text=calendarText([{uid:'meeting-123',title:'Training, prep; '+ '🍖'.repeat(40)+'\nEND:VEVENT',start:'2030-01-01T18:00:00Z',updated:'2030-01-01T17:00:00Z',status:'CONFIRMED',sequence:2}]);assert.ok(!text.includes('DTEND:'));assert.ok(text.includes('SUMMARY:Training\\, prep\\;'));assert.equal(text.split('\r\n').filter(x=>x==='END:VEVENT').length,1);for(const line of text.split('\r\n'))assert.ok(Buffer.byteLength(line)<=75);
});
