import {zone,today,type Training} from './domain.ts';
import type {TrainingPosition,TrainingSignoff} from './trainingProgress.ts';
export type Person={id:string;staff_id?:string;name:string;group:string;active:boolean;on_roster:boolean;is_trainer:boolean;primary_job_id?:string;is_ca?:boolean;version?:number};
export type WorkShift={id:string;person_id:string;start:string;end:string;slot:number;job_id:string|null;qualification_reason?:string};
export type Revision={id:string;state:'Draft'|'Queued'|'Published'|'Attention';version:number;shifts:WorkShift[];base_id:string|null;release_at:string|null;release_name:string;error:string|null};
export type ScheduleRequest={id:string;kind:string;person_id:string;created_by:string;status:string;version:number;reason?:string;response?:string;claimed_by?:string;created_at?:string;decided_at?:string;decided_name?:string;payload:{start?:string;end?:string;effective?:string;until?:string|null;category?:'PTO'|'RTO';paid_hours?:number|null;request_id?:string;request_version?:number;days?:number[][][];source?:WorkShift;target?:WorkShift;recipient?:string}};
export type Announcement={id:string;title:string;body:string;groups:string[];active:boolean;version:number;created_by:string;author:string;created_at:string;read:boolean};
export type LinkedTraining=Training&{ends_at?:string;work_shift_id?:string;trainer_shift_id?:string;schedule_revision_id?:string};
export type Workspace='employee'|'manager'|'it';
export type WorkspaceSession={id:string;name:string;person_id:string;views:Workspace[];is_ca:boolean};
export type SchedulerData={workspace?:Workspace;available_views?:Workspace[];self:{id:string;person_id:string;staff_id?:string;name:string;is_manager:boolean;is_ca:boolean;is_admin:boolean};week:{start:string;published_id:string|null;draft:Revision|null};people:Person[];published:{week:string;revision_id:string;shifts:WorkShift[]}[];jobs:TrainingPosition[];training:LinkedTraining[];signoffs:TrainingSignoff[];appointments:{id:string;scheduled_at:string;status:string;type:string;manager:string;employee:string}[];requests:ScheduleRequest[];announcements:Announcement[];announcement_history?:{id:number;announcement_id:string;at:string;value:Announcement}[];notifications:{id:string;body:string;created_at:string;read_at:string|null}[];accounts:{id:string;staff_id:string;active:boolean;is_ca:boolean;version:number;role?:string;manager_version?:number}[];service:{email_verified?:boolean;email_evidence?:string;last_worker_at?:string};releases:{id:string;week:string;state:string;release_at:string;release_name:string;error:string}[];audit:{id:number;actor_name:string;action:string;record_id:string;changed_at:string;before_value:unknown;after_value:unknown}[]};
export type Act=(action:string,payload:Record<string,unknown>)=>Promise<Record<string,unknown>>;
export function shiftDay(iso:string){return new Intl.DateTimeFormat('sv-SE',{timeZone:zone}).format(new Date(iso))}
export function addDays(day:string,n:number){const d=new Date(day+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+n);return d.toISOString().slice(0,10)}
export function weekOf(day=today()){return addDays(day,-new Date(day+'T12:00:00Z').getUTCDay())}
export function localFields(iso:string){const p=Object.fromEntries(new Intl.DateTimeFormat('en-US',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date(iso)).map(x=>[x.type,x.value]));return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`}
export function localCandidates(local:string){if(!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(local))return [];return [5,6].map(offset=>new Date(Date.parse(local+':00Z')+offset*3600000).toISOString()).filter(iso=>localFields(iso)===local)}
export function centralInstant(local:string,occurrence=''){const candidates=localCandidates(local);if(!candidates.length)throw Error('That Central time does not exist. Choose another time.');if(candidates.length>1&&!['earlier','later'].includes(occurrence))throw Error('This time occurs twice when daylight saving ends. Choose the first or second occurrence.');return candidates[occurrence==='later'?candidates.length-1:0]}
export function clockTime(iso:string){return new Intl.DateTimeFormat('en-US',{timeZone:zone,hour:'numeric',minute:'2-digit'}).format(new Date(iso))}
export function hours(shifts:WorkShift[]){return Math.round(shifts.reduce((n,s)=>n+(Date.parse(s.end)-Date.parse(s.start))/3600000,0)*100)/100}
export function scheduleChanges(before:WorkShift[],after:WorkShift[]){return {added:after.filter(s=>!before.some(p=>p.id===s.id)),changed:after.filter(s=>before.some(p=>p.id===s.id&&['person_id','start','end','slot','job_id','qualification_reason'].some(k=>p[k as keyof WorkShift]!==s[k as keyof WorkShift]))),removed:before.filter(s=>!after.some(p=>p.id===s.id))}}

// A trainer must be assigned to this job and cover the work interval. Merely
// having a trainer elsewhere on the roster must not hide the reminder.
export function qualificationWarnings(data:SchedulerData,shifts:WorkShift[]){
 const published=data.published.flatMap(w=>w.shifts);
 const currentIds=new Set(shifts.map(s=>s.id));
 const available=[...shifts,...published.filter(s=>!currentIds.has(s.id)&&shiftDay(s.start)<data.week.start),...published.filter(s=>!currentIds.has(s.id)&&shiftDay(s.start)>=addDays(data.week.start,7))];
 return shifts.flatMap(s=>{
  const person=data.people.find(p=>p.id===s.person_id);
  if(!s.job_id||!person?.staff_id||data.signoffs.some(f=>f.staff_id===person.staff_id&&f.training_position_id===s.job_id&&f.active))return [];
  const intervals=data.training.filter(t=>t.status==='Scheduled'&&t.work_shift_id===s.id&&t.staff_id===person.staff_id&&t.training_position_id===s.job_id&&t.ends_at&&(!t.schedule_revision_id||t.schedule_revision_id===data.week.draft?.id||data.published.some(w=>w.revision_id===t.schedule_revision_id))).flatMap(t=>{
   const trainer=available.find(x=>x.id===t.trainer_shift_id&&x.person_id==='s:'+t.trainer_id);
   const eligible=data.people.some(p=>p.staff_id===t.trainer_id&&p.active&&p.is_trainer);
   return trainer&&eligible&&Date.parse(trainer.start)<=Date.parse(t.scheduled_at)&&Date.parse(trainer.end)>=Date.parse(t.ends_at!)?[[Date.parse(t.scheduled_at),Date.parse(t.ends_at!)]]:[];
  }).sort((a,b)=>a[0]-b[0]);
  let covered=Date.parse(s.start);for(const [start,end] of intervals){if(start>covered)break;covered=Math.max(covered,end)}
  return covered>=Date.parse(s.end)?[]:[`${person.name} · ${data.jobs.find(j=>j.id===s.job_id)?.name||'Assigned job'} · ${shiftDay(s.start)} ${clockTime(s.start)}: not signed off and scheduled without a trainer for all or part of this shift.`];
 });
}
