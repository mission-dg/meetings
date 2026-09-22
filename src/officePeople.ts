import type {Person,SchedulerData} from './scheduler';

// This narrows the management-board picker, not account permissions or the
// server's assignment eligibility rules.
export function managementPerson(p:Person,data:SchedulerData){
 if(!p.active||!p.on_roster)return false;
 if(p.group==='SHL'||p.is_ca||data.meeting_managers?.some(m=>m.person_id===p.id))return true;
 const jobs=data.jobs.filter(j=>j.active&&['SHL','hSHL','sSHL','CA','TA','GM'].includes(j.name));
 return jobs.some(j=>j.id===p.primary_job_id||!!p.staff_id&&data.signoffs.some(f=>f.staff_id===p.staff_id&&f.training_position_id===j.id&&f.active));
}
