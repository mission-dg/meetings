import type {ScheduleRequest} from './scheduler.ts';

export const weekdays=['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
export type AvailabilityDays=number[][][];
export function approvedAvailability(requests:ScheduleRequest[],person:string,date:string){
 return requests.filter(q=>q.kind==='Availability'&&q.person_id===person&&q.status==='Approved'&&q.payload.effective!<=date)
  .sort((a,b)=>b.payload.effective!.localeCompare(a.payload.effective!)||(b.created_at||'').localeCompare(a.created_at||'')||b.id.localeCompare(a.id))[0];
}
export function upcomingAvailability(requests:ScheduleRequest[],person:string,date:string){
 const dates=[...new Set(requests.filter(q=>q.kind==='Availability'&&q.person_id===person&&q.status==='Approved'&&q.payload.effective!>date).map(q=>q.payload.effective!))].sort();
 return dates.map(day=>approvedAvailability(requests,person,day)!);
}
export function minuteLabel(value:number){
 if(value===1440)return 'Midnight';
 const hour=Math.floor(value/60),minute=value%60;
 return `${hour%12||12}:${String(minute).padStart(2,'0')} ${hour<12?'AM':'PM'}`;
}
export function availabilityLabel(ranges:number[][]){
 return ranges.length?ranges.map(([start,end])=>start===0&&end===1440?'All day':`${minuteLabel(start)} – ${minuteLabel(end)}`).join(', '):'Unavailable';
}
export function validateAvailability(days:AvailabilityDays){
 if(!Array.isArray(days)||days.length!==7)throw Error('Set availability for all seven days.');
 days.forEach((ranges,i)=>{
  let end=-1;
  for(const [a,b] of ranges){
   if(!Number.isInteger(a)||!Number.isInteger(b)||a<0||b>1440||a>=b||a<end)throw Error(`${weekdays[i]}: enter time windows in order without overlaps. For overnight availability, use both days.`);
   end=b;
  }
 });
 return days;
}
