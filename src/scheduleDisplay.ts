import {centralInstant,localFields,shiftDay,type WorkShift,type Person,type ScheduleRequest} from './scheduler.ts';
import type {TrainingPosition} from './trainingProgress.ts';
export function mealPeriod(s:WorkShift):'Lunch'|'Dinner'{
 if(Number(localFields(s.start).slice(11,13))>=14)return 'Dinner';
 const boundary=Date.parse(centralInstant(shiftDay(s.start)+'T16:00'));
 const after=Math.max(0,Date.parse(s.end)-Math.max(boundary,Date.parse(s.start)));
 return after>(Date.parse(s.end)-Date.parse(s.start))/2?'Dinner':'Lunch';
}
export function assignmentGroup(s:WorkShift,jobs:TrainingPosition[]){
 return s.assignment_type==='opening_office'||s.assignment_type==='closing_office'?'SHL':jobs.find(j=>j.id===s.job_id)?.department||'SHL';
}
export function visibleAssignments(shifts:WorkShift[],jobs:TrainingPosition[],group:string,person:string|null){return shifts.filter(s=>(!group||assignmentGroup(s,jobs)===group)&&(!person||s.person_id===person));}
export function sortedAssignments(shifts:WorkShift[],people:Person[]){return [...shifts].sort((a,b)=>Date.parse(a.start)-Date.parse(b.start)||(people.find(p=>p.id===a.person_id)?.name||'').localeCompare(people.find(p=>p.id===b.person_id)?.name||'')||a.id.localeCompare(b.id));}
export function absencesOnDay(requests:ScheduleRequest[],day:string){const start=Date.parse(centralInstant(day+'T00:00'));const next=new Date(day+'T12:00Z');next.setUTCDate(next.getUTCDate()+1);const end=Date.parse(centralInstant(next.toISOString().slice(0,10)+'T00:00'));return requests.filter(q=>q.kind==='Time off'&&q.status==='Approved'&&Date.parse(q.payload.start!)<end&&Date.parse(q.payload.end!)>start);}
