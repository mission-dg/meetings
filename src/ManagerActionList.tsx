import {displayTime} from './domain';
import type {SchedulerData} from './scheduler';
export function ManagerActionList({data,go}:{data:SchedulerData;go:(p:string)=>void}){
 const tasks:{id:string;label:string;target:string}[]=[];
 for(const q of data.requests.filter(q=>['Pending','Accepted'].includes(q.status)))tasks.push({id:q.id,label:`${data.people.find(p=>p.id===q.person_id)?.name||'Teammate'} · ${q.kind} · ${q.created_by===data.self.id?'Needs another manager':'Review request'}`,target:'requests?request='+encodeURIComponent(q.id)});
 for(const r of data.releases.filter(r=>r.state==='Attention'))tasks.push({id:r.id,label:'Release needs attention · '+r.week,target:'schedule?week='+r.week});
 for(const t of data.training.filter(t=>t.status==='Scheduled'&&Date.parse(t.ends_at||t.scheduled_at)<Date.now()))tasks.push({id:t.id,label:`Training follow-up · ${data.people.find(p=>p.staff_id===t.staff_id)?.name||'Teammate'} · ${displayTime(t.scheduled_at)}`,target:'training?person='+encodeURIComponent('s:'+t.staff_id)});
 for(const d of [...new Map((data.meeting_due||[]).map(d=>[d.staff_id,d])).values()])tasks.push({id:'meeting-'+d.staff_id,label:'1:1 reminder · '+(data.people.find(p=>p.staff_id===d.staff_id)?.name||'Teammate'),target:'oneOnOnes?person='+encodeURIComponent('s:'+d.staff_id)});
 return <section className="panel scheduler-card" data-tour="manager-actions"><h2>Manager action list</h2><p>Requests, release problems, training follow-ups and 1:1 reminders. Coverage and hours checks for the selected week appear below.</p>{tasks.length?<ul>{tasks.map(t=><li key={t.id}><button onClick={()=>go(t.target)}>{t.label}</button></li>)}</ul>:<p>No pending items in the records loaded for this workspace. Check the coverage assessment before treating the week as ready.</p>}</section>
}
