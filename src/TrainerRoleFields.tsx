import {useState} from 'react';
import {positionName,type Employee} from './domain';
import type {TrainingPosition} from './trainingProgress';
export function TrainerRoleFields({employee,jobs}:{employee?:Employee;jobs:TrainingPosition[]}){
 const [enabled,setEnabled]=useState(!!employee?.is_trainer),[roles,setRoles]=useState(employee?.trainer_job_ids||[]);
 return <><label className="check"><input name="trainer" type="checkbox" checked={enabled} onChange={e=>setEnabled(e.target.checked)}/>Trainer · available to train employees</label>{enabled&&<fieldset><legend>Trainer roles</legend><p>Select every job this employee is authorized to train. This does not grant a job qualification or account permissions.</p>{['FOH','BOH','Catering'].map(group=><div key={group}><strong>{positionName(group)}</strong>{jobs.filter(j=>j.active&&j.department===group).map(j=><label className="check" key={j.id}><input name="trainerJobs" type="checkbox" value={j.id} checked={roles.includes(j.id)} onChange={e=>setRoles(e.target.checked?[...roles,j.id]:roles.filter(id=>id!==j.id))}/>{j.name}</label>)}</div>)}{!roles.some(id=>jobs.some(j=>j.id===id&&j.active))&&<p className="notice">Select at least one trainer role before saving.</p>}</fieldset>}</>;
}
