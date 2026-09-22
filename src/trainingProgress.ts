export type TrainingPosition={id:string;name:string;department?:'FOH'|'BOH'|'Catering'|'SHL';version?:number;target_shifts:number;active:boolean};
type ProgressSession={staff_id:string;training_position_id?:string|null;status:string;scheduled_at:string;shift:number};
export function trainingProgress(staffId:string,position:TrainingPosition,sessions:ProgressSession[],signoffs:TrainingSignoff[]=[]){
 const rows=sessions.filter(s=>s.staff_id===staffId&&s.training_position_id===position.id);
 const recorded=new Set(rows.filter(s=>s.status==='Completed').map(s=>new Intl.DateTimeFormat('sv-SE',{timeZone:'America/Chicago'}).format(new Date(s.scheduled_at))+':'+s.shift)).size;
 const qualified=signoffs.some(s=>s.staff_id===staffId&&s.training_position_id===position.id&&s.active);
 const completed=qualified?Math.max(recorded,position.target_shifts):recorded;
 return {completed,target:position.target_shifts,remaining:Math.max(0,position.target_shifts-completed),scheduled:rows.filter(s=>s.status==='Scheduled').length,started:rows.length>0};
}

export type TrainingSignoff={origin?:'training'|'experience'|'migration';id:string;staff_id:string;training_position_id:string;active:boolean;created_by:string;created_at:string;version:number};

export function trainingBadge(staffId:string,position:TrainingPosition,sessions:ProgressSession[],signoffs:TrainingSignoff[]){
 const progress=trainingProgress(staffId,position,sessions);
 const trained=signoffs.some(s=>s.staff_id===staffId&&s.training_position_id===position.id&&s.active);
 return {color:trained?'teal':progress.scheduled>0||progress.completed>0?'blue':'red',text:`${position.name}: ${trained?'Trained':`${progress.completed}/${progress.target} Shifts`}`};
}
