import {useState} from 'react';
import {type SchedulerData,type ScheduleRequest} from './scheduler';
import {today,displayTime,positionName} from './domain';
import {approvedAvailability,upcomingAvailability,availabilityLabel,weekdays,type AvailabilityDays} from './availability';

export function AvailabilitySummary({days}:{days?:AvailabilityDays}){
 return <dl className="availability-summary">{days?.map((ranges,i)=><div key={i} className={ranges.length?'':'unavailable'}><dt>{weekdays[i]}</dt><dd>{availabilityLabel(ranges)}</dd></div>)}</dl>;
}
export function DecisionDetails({request}:{request:ScheduleRequest}){
 return request.decided_at?<p className="muted">{request.status==='Withdrawn'?'Approval withdrawn':request.status==='Rejected'?'Denied':request.status} by {request.decided_name||'a manager'} · {displayTime(request.decided_at)}</p>:null;
}
function ApprovedHours({data,person}:{data:SchedulerData;person:string}){
 const current=approvedAvailability(data.requests,person,today()),upcoming=upcomingAvailability(data.requests,person,today());
 const pending=data.requests.filter(q=>q.person_id===person&&q.kind==='Availability'&&q.status==='Pending');
 return <><h3>Current approved availability</h3>{current?<><p className="muted">Effective from {current.payload.effective}{current.payload.until?' through '+current.payload.until:''} · Repeats weekly in Central time</p><AvailabilitySummary days={current.payload.days}/><DecisionDetails request={current}/></>:<p className="muted">No approved availability on file. Scheduling has no recurring availability restrictions yet.</p>}
 {pending.length>0&&<p className="notice" role="status">{pending.length} {pending.length===1?'change is':'changes are'} awaiting manager approval. Current approved hours still apply.</p>}
 {upcoming.map(q=><details key={q.id}><summary>Approved upcoming change · Starts {q.payload.effective}</summary><AvailabilitySummary days={q.payload.days}/><DecisionDetails request={q}/></details>)}</>;
}
export function AvailabilityOverview({data,busy,onRequest}:{data:SchedulerData;busy:boolean;onRequest:()=>void}){
 const [person,setPerson]=useState(''),[search,setSearch]=useState('');
 const onRoster=data.people.find(p=>p.id===data.self.person_id)?.on_roster;
 return <div className="availability-overview">{!data.self.is_manager&&<section className="panel scheduler-card"><div className="section-title"><div><h2>Current availability</h2><p className="muted">Your accepted weekly pattern stays in effect while changes await manager approval. Use Request time off below for a specific day.</p></div><button className="primary" disabled={busy||!onRoster} onClick={onRequest}>{approvedAvailability(data.requests,data.self.person_id,today())?'Request availability change':'Set availability'}</button></div>
 {!onRoster&&<p className="muted">Your account is off the work roster. IT can add it in People & access.</p>}
 <ApprovedHours data={data} person={data.self.person_id}/></section>}
 {data.self.is_manager&&<section className="panel scheduler-card"><h2>Approved team availability</h2><p className="muted">Look up approved hours and upcoming changes before planning shifts.</p><div className="form-grid"><label>Find a team member<input type="search" value={search} onChange={e=>{setSearch(e.target.value);setPerson('')}} placeholder="Search by name"/></label><label>Team member<select value={person} onChange={e=>setPerson(e.target.value)}><option value="">Choose a team member</option>{data.people.filter(p=>p.on_roster&&p.name.toLowerCase().includes(search.toLowerCase())).map(p=><option key={p.id} value={p.id}>{p.name} · {positionName(p.group)}{p.active?'':' · Inactive'}</option>)}</select></label></div>{person&&<ApprovedHours data={data} person={person}/>}</section>}</div>;
}
const timeText=(minute:number)=>`${String(Math.floor(minute/60)%24).padStart(2,'0')}:${String(minute%60).padStart(2,'0')}`;
type DayFields={mode:string;ranges:{start:string;end:string}[]};
export function AvailabilityFields({data}:{data:SchedulerData}){
 const initial=approvedAvailability(data.requests,data.self.person_id,today())?.payload.days;
 const [days,setDays]=useState<DayFields[]>(()=>weekdays.map((_,i)=>{const ranges=initial?.[i]??[[0,1440]];return {mode:!ranges.length?'unavailable':ranges.length===1&&ranges[0][0]===0&&ranges[0][1]===1440?'all':'hours',ranges:ranges.length?ranges.map(([a,b])=>({start:timeText(a),end:timeText(b)})):[{start:'09:00',end:'17:00'}]}}));
 const minutes=(v:string)=>v?Number(v.slice(0,2))*60+Number(v.slice(3)):null;
 const encoded=days.map(d=>d.mode==='unavailable'?[]:d.mode==='all'?[[0,1440]]:d.ranges.map(r=>[minutes(r.start),r.end==='00:00'?1440:minutes(r.end)]));
 function update(i:number,value:Partial<DayFields>){setDays(all=>all.map((d,j)=>i===j?{...d,...value}:d))}
 return <><label>Effective from<input name="effective" type="date" required min={today()} defaultValue={today()}/></label><label>Temporary pattern ends (optional)<input name="until" type="date" min={today()}/></label><p className="muted">Leave the end date blank for regular availability. Temporary patterns return to your approved regular hours after the end date.</p><p className="muted">Weekly availability · Central time. Your current approved hours are prefilled. A pending or denied request does not change them. Use time off for a one-time absence.</p><p className="muted">For overnight hours, set both days. An end time of 12:00 AM means midnight at the end of that day.</p>
 <input type="hidden" name="availability" value={JSON.stringify(encoded)}/>
 {days.map((d,i)=><div className="availability-editor-day" key={i}><label>{weekdays[i]}<select aria-label={weekdays[i]+' availability'} value={d.mode} onChange={e=>update(i,{mode:e.target.value,...(e.target.value==='hours'&&d.mode!=='hours'?{ranges:[{start:'09:00',end:'17:00'}]}:{})})}><option value="all">Available all day</option><option value="hours">Specific hours</option><option value="unavailable">Unavailable</option></select></label>{d.mode==='hours'&&<div className="availability-windows">{d.ranges.map((range,j)=><div className="availability-window" key={j}><label>From<input type="time" required aria-label={`${weekdays[i]} window ${j+1} starts`} value={range.start} onChange={e=>update(i,{ranges:d.ranges.map((r,n)=>n===j?{...r,start:e.target.value}:r)})}/></label><label>Until<input type="time" required aria-label={`${weekdays[i]} window ${j+1} ends`} value={range.end} onChange={e=>update(i,{ranges:d.ranges.map((r,n)=>n===j?{...r,end:e.target.value}:r)})}/></label>{d.ranges.length>1&&<button type="button" aria-label={`Remove ${weekdays[i]} window ${j+1}`} onClick={()=>update(i,{ranges:d.ranges.filter((_,n)=>n!==j)})}>Remove</button>}</div>)}<button type="button" className="add-window" aria-label={`Add ${weekdays[i]} time window`} onClick={()=>update(i,{ranges:[...d.ranges,{start:'',end:''}]})}>Add time window</button></div>}</div>)}
 </>;
}
