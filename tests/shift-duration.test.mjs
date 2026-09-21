import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validateWorkShiftTimes} from '../src/scheduler.ts';
import {fixture} from './scheduler-fixture.mjs';
test('shift time checks reject reversed, equal and over-12-hour intervals',()=>{
 const start='2030-09-02T16:00:00Z';
 for(const end of ['2030-09-02T15:00Z',start])assert.throws(()=>validateWorkShiftTimes(start,end),/after start/);
 assert.throws(()=>validateWorkShiftTimes(start,'2030-09-03T04:01Z'),/12 hours/);
 assert.doesNotThrow(()=>validateWorkShiftTimes(start,'2030-09-03T04:00Z'));
 assert.throws(()=>validateWorkShiftTimes('invalid',start),/valid/);
 // Elapsed time, including the repeated fall-back hour.
 assert.throws(()=>validateWorkShiftTimes('2030-11-02T20:00:00-05:00','2030-11-03T08:00:00-06:00'),/12 hours/);
});
test('server rejects invalid drafts atomically and accepts exactly 12 hours overnight',async()=>{
 const {db,act,read,shift}=await fixture();try{
 await act(1,'draft',{week:'2030-09-01'});const d=(await read(1)).week.draft;
 for(const [end,error] of [['2030-09-02T15:00Z',/after start/],['2030-09-02T16:00Z',/after start/],['2030-09-03T04:01Z',/12 hours/]]){
 await assert.rejects(act(1,'save',{id:d.id,version:d.version,shifts:[shift(1,'s:Casey.W','2030-09-02T16:00Z',end)]}),error);
 assert.equal((await read(1)).week.draft.version,d.version);assert.deepEqual((await read(1)).week.draft.shifts,[]);
 }
 await act(1,'save',{id:d.id,version:d.version,shifts:[shift(1,'s:Casey.W','2030-09-02T16:00Z','2030-09-03T04:00Z')]});
 assert.equal((await read(1)).week.draft.shifts.length,1);
 }finally{await db.close()}
});
