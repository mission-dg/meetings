import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {fixture,uid,sid} from './scheduler-fixture.mjs';
import {colorPresets,defaultAppearance,appearanceColors,shiftColorKey,colorEntries,styledPreset,presetGroups,presetLuminance} from '../src/scheduleColors.ts';
async function setup(){const f=await fixture();const files=await readdir(new URL('../supabase/migrations/',import.meta.url));try{for(let n=29;n<=37;n++){const file=files.find(x=>x.startsWith(String(n).padStart(3,'0')+'_'));await f.db.exec(await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));}return f}catch(e){await f.db.close();throw e}}
const luminance=hex=>{const c=hex.slice(1).match(/../g).map(x=>parseInt(x,16)/255).map(x=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4);return c[0]*.2126+c[1]*.7152+c[2]*.0722};
const contrast=(a,b)=>(Math.max(luminance(a),luminance(b))+.05)/(Math.min(luminance(a),luminance(b))+.05);
test('presets have readable light/dark labels and palettes preserve unique stable assignments',()=>{for(const base of colorPresets)for(const palette of ['classic','vivid','soft']){const p=styledPreset(base,palette);assert.ok(contrast('#292722',p.background)>=4.5,p.id+' light');assert.ok(contrast(p.edge,p.background)>=3,p.id+' boundary');assert.ok(contrast('#ffffff',p.darkBackground)>=4.5,p.id+' dark card');assert.ok(contrast(p.darkEdge,p.darkBackground)>=3,p.id+' dark accent')};const jobs=[{id:'a',name:'GSR',active:true},{id:'b',name:'Line',active:true}];const a=defaultAppearance(jobs);assert.equal(new Set(Object.values(appearanceColors(a).assignments)).size,7);a.palette='vivid';a.overrides['job:a']='rose';assert.equal(appearanceColors(a).assignments['job:a'],'rose');assert.equal(shiftColorKey({id:'s',job_id:'a'}),'job:a');assert.equal(shiftColorKey({id:'s',job_id:null,assignment_type:'training'},{s:'meeting'}),'type:staff_meeting');assert.equal(shiftColorKey({id:'s',job_id:'a',assignment_type:'regular'},{s:'meeting'}),'job:a');assert.equal(colorEntries(jobs,new Set(['job:b']))[0].label,'Line');});
test('personal preferences are isolated, versioned, retry-safe and reject invalid callers and colors',async()=>{const f=await setup();try{
 const read=async n=>(await f.as(n,'select appearance_read() r')).rows[0].r;
 const original=await read(4);assert.equal(original.mode,'light');assert.equal(Object.keys(original.defaults).length,(await f.db.query('select count(*)::int n from training_positions')).rows[0].n+5);
 const args=[0,'dark','vivid',{['job:'+f.gsr]:'rose'},sid(800)];
 const save=async(n,a)=>(await f.as(n,'select appearance_save($1,$2,$3,$4,$5) r',a)).rows[0].r;
 const result=await save(4,args);assert.equal(result.version,1);assert.deepEqual(await save(4,args),result);assert.equal((await read(5)).mode,'light');assert.equal((await read(1)).mode,'light');
 await assert.rejects(save(4,[0,'light','classic',{},sid(801)]),/another device/);
 await assert.rejects(save(4,[1,'dark','classic',{'job:bad':'rose'},sid(802)]),/valid job/);
 await assert.rejects(save(4,[1,'dark','classic',{'type:shl':'#fff'},sid(803)]),/valid job/);
 await assert.rejects(save(4,[1,'nope','classic',{},sid(804)]),/Invalid appearance/);
 await assert.rejects(save(6,[0,'dark','classic',{},sid(805)]),/Active account/);
 await assert.rejects(f.as(4,'select * from private.appearance_preferences'),/permission denied/);
 await f.db.exec('set role anon');await assert.rejects(f.db.query('select appearance_read()'),/permission denied/);await f.db.exec('reset role');
 const before=await read(4);await f.db.exec("insert into training_positions(name,department,created_by) values('New color job','FOH','00000000-0000-0000-0000-000000000001')");const after=await read(4);for(const k in before.defaults)assert.equal(after.defaults[k],before.defaults[k]);
 await f.db.query("update training_positions set name='Renamed',active=false where id=$1",[f.gsr]);assert.equal((await read(4)).overrides['job:'+f.gsr],'rose');
 }finally{await f.db.close()}});
test('staff meeting links annotate only visible generated training shifts and never reveal draft meetings to employees',async()=>{const f=await setup();try{
 const draft=await f.act(1,'draft',{week:'2030-09-01'});const shift={...f.shift(1),job_id:null,assignment_type:'training',activity_title:'Same title'};
 await f.db.query('update private.schedule_revisions set shifts=$1 where id=$2',[[shift],draft.id]);
 await f.db.query("insert into private.staff_meetings(id,title,starts_at,ends_at,mode,week,people,generated,created_by) values($1,'Private title',$2,$3,'separate','2030-09-01',array['s:Casey.W'],$4,$5)",[sid(900),shift.start,shift.end,[shift],uid(1)]);
 const workspace=async(n,v)=>(await f.as(n,"select workspace_read('2030-09-01',$1) r",[v])).rows[0].r;
 assert.equal((await workspace(1,'it')).schedule_meeting_shifts[shift.id],sid(900));assert.deepEqual((await workspace(4,'employee')).schedule_meeting_shifts,{});
 await f.db.query("update private.schedule_revisions set state='Published' where id=$1",[draft.id]);await f.db.query('update private.schedule_weeks set published_id=$1,draft_id=null where week_start=$2',[draft.id,'2030-09-01']);
 const employee=await workspace(4,'employee');assert.equal(employee.schedule_meeting_shifts[shift.id],sid(900));assert.ok(!JSON.stringify(employee.schedule_meeting_shifts).includes('Private title'));
 }finally{await f.db.close()}});

test('picker groups hues and orders light to dark without changing saved preset identities',()=>{const shown=presetGroups.flatMap(g=>g.presets);assert.equal(shown.length,colorPresets.length);assert.equal(new Set(shown.map(p=>p.id)).size,colorPresets.length);assert.equal(presetGroups[0].label,'Reds & pinks');assert.equal(presetGroups[1].label,'Blues');for(const group of presetGroups)for(let i=1;i<group.presets.length;i++)assert.ok(presetLuminance(group.presets[i-1].edge)>=presetLuminance(group.presets[i].edge));});
