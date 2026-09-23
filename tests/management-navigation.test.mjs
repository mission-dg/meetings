import {test} from 'node:test';
import assert from 'node:assert/strict';
import {workspacePages,allowedPage,chooseWorkspace,canonicalPage} from '../src/workspaces.ts';
import {guides} from '../src/helpGuides.ts';
import {leadershipPerson} from '../src/accountGroups.ts';
test('IT includes every manager destination without switching and preserves employee boundary',()=>{
 for(const [page] of workspacePages.manager)assert.ok(allowedPage('it',page),page);
 for(const page of ['accounts','audit','oneOnOnes','gmRequests'])assert.equal(allowedPage('employee',page),false);
 assert.equal(allowedPage('employee','settings'),true);
 assert.equal(chooseWorkspace({views:['it','manager','employee']},'manager'),'it');
 assert.equal(chooseWorkspace({views:['it','manager','employee']},'employee'),'employee');
 assert.equal(canonicalPage('administration'),'accounts');assert.equal(canonicalPage('meetings'),'oneOnOnes');assert.equal(canonicalPage('staff'),'directory');
});
test('help guides have unique durable identifiers and reachable tasks',()=>{
 assert.equal(new Set(guides.map(g=>g.id)).size,guides.length);
 for(const g of guides){assert.ok(g.steps.length);assert.ok(g.recovery);assert.ok(g.page==='profile'||allowedPage('manager',g.page),g.id)}
});
test('account tabs distinguish leadership by assignment or qualification without name matching',()=>{
 const data={people:[{id:'s:a',staff_id:'a',group:'FOH'},{id:'s:b',staff_id:'b',group:'FOH'},{id:'m:c',group:'SHL'}],accounts:[],jobs:[{id:'hourly',name:'hSHL'}],signoffs:[{staff_id:'b',training_position_id:'hourly',active:true}]};
 assert.equal(!!leadershipPerson(data,'s:a'),false);assert.equal(!!leadershipPerson(data,'s:b'),true);assert.equal(!!leadershipPerson(data,'m:c'),true);
 data.signoffs[0].active=false;assert.equal(!!leadershipPerson(data,'s:b'),false);
});
