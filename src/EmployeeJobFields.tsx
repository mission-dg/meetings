import {useState} from 'react';
import {type Employee,positionName} from './domain';
import type {TrainingPosition} from './trainingProgress';
export function EmployeeJobFields({employee,positions}:{employee?:Employee;positions:TrainingPosition[]}){
 const [primary,setPrimary]=useState(employee?.primary_job_id||'');const job=positions.find(p=>p.id===primary);
 return <><label>Primary job<select required name="primaryJob" value={primary} onChange={e=>setPrimary(e.target.value)}><option value="">Choose a primary job</option>{['FOH','BOH','Catering'].map(group=><optgroup label={positionName(group)} key={group}>{positions.filter(p=>p.department===group&&p.active).map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</optgroup>)}</select></label><input type="hidden" name="department" value={job?.department||employee?.department||'FOH'}/><p className="muted">Primary group: {job?positionName(job.department):'Choose a job'}. Additional qualifications can span every group and remain when the primary job changes.</p></>;
}
