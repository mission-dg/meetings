import {useState} from 'react';
import {type Employee,positionName} from './domain';
import type {TrainingPosition} from './trainingProgress';
export function EmployeeJobFields({employee,positions}:{employee?:Employee;positions:TrainingPosition[]}){
 const [group,setGroup]=useState<Employee['department']>(employee?.department||'FOH'),[primary,setPrimary]=useState(employee?.primary_job_id||'');
 const jobs=positions.filter(p=>p.department===group&&(p.active||p.id===employee?.primary_job_id));
 return <><label>Position group<select name="department" value={group} onChange={e=>{setGroup(e.target.value as Employee['department']);setPrimary('')}}><option>FOH</option><option value="BOH">HOH</option><option>Catering</option></select></label><label>Primary job<select name="primaryJob" value={primary} onChange={e=>setPrimary(e.target.value)}><option value="">Not assigned yet</option>{jobs.map(p=><option value={p.id} key={p.id}>{p.name}{p.active?'':' · Archived'}</option>)}</select></label><p className="muted">The primary job is used for employee lookup. Training and qualifications for additional jobs are tracked separately and remain when the primary job changes.</p>{!jobs.length&&<p className="muted">Add a {positionName(group)} job under Training progress to assign it here.</p>}</>;
}
