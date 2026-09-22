import {centralInstant,localFields,shiftDay,type WorkShift,type Person,type ScheduleRequest} from './scheduler.ts';
import type {TrainingPosition} from './trainingProgress.ts';
export function mealPeriod(s:WorkShift):'Lunch'|'Dinner'{
 if(Number(localFields(s.start).slice(11,13))>=14)return 'Dinner';
 const boundary=Date.parse(centralInstant(shiftDay(s.start)+'T16:00'));
 const after=Math.max(0,Date.parse(s.end)-Math.max(boundary,Date.parse(s.start)));
 return after>(Date.parse(s.end)-Date.parse(s.start))/2?'Dinner':'Lunch';
}
export function assignmentGroup(s:WorkShift,jobs:TrainingPosition[]){
 return s.assignment_type==='training'?'Training':s.assignment_type==='opening_office'||s.assignment_type==='closing_office'?'SHL':jobs.find(j=>j.id===s.job_id)?.department||'SHL';
}
export function visibleAssignments(shifts:WorkShift[],jobs:TrainingPosition[],group:string,person:string|null){return shifts.filter(s=>(!group||assignmentGroup(s,jobs)===group)&&(!person||s.person_id===person));}
export function sortedAssignments(shifts:WorkShift[],people:Person[]){return [...shifts].sort((a,b)=>Date.parse(a.start)-Date.parse(b.start)||(people.find(p=>p.id===a.person_id)?.name||'').localeCompare(people.find(p=>p.id===b.person_id)?.name||'')||a.id.localeCompare(b.id));}
export function absencesOnDay(requests:ScheduleRequest[],day:string){const start=Date.parse(centralInstant(day+'T00:00'));const next=new Date(day+'T12:00Z');next.setUTCDate(next.getUTCDate()+1);const end=Date.parse(centralInstant(next.toISOString().slice(0,10)+'T00:00'));return requests.filter(q=>q.kind==='Time off'&&q.status==='Approved'&&Date.parse(q.payload.start!)<end&&Date.parse(q.payload.end!)>start);}

export const hourCategories=['FOH','BOH','Catering','SHL','Training'] as const;
export function categoryHours(shifts:WorkShift[],people:Person[],jobs:TrainingPosition[]){
 const sums:Record<string,number>={Total:0,FOH:0,BOH:0,Catering:0,SHL:0,Training:0};const seen=new Set<string>();
 for(const s of shifts){if(seen.has(s.id)||people.find(p=>p.id===s.person_id)?.employment_type==='Salaried')continue;seen.add(s.id);const ms=Date.parse(s.end)-Date.parse(s.start);if(!Number.isFinite(ms)||ms<=0)continue;const group=assignmentGroup(s,jobs);sums[group]+=ms/3600000;}
 for(const g of hourCategories)sums[g]=Math.round(sums[g]*100)/100;
 sums.Total=Math.round(hourCategories.reduce((n,g)=>n+sums[g],0)*100)/100;return sums;
}
