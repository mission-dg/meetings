export type TrainingPosition={id:string;name:string;department?:'FOH'|'BOH'|'Catering'|'SHL';version?:number;target_shifts:number;active:boolean};
type ProgressSession={staff_id:string;training_position_id?:string|null;status:string;scheduled_at:string;shift:number};
export function trainingProgress(staffId:string,position:TrainingPosition,sessions:ProgressSession[],signoffs:TrainingSignoff[]=[]){
 const rows=sessions.filter(s=>s.staff_id===staffId&&s.training_position_id===position.id);
 const recorded=new Set(rows.filter(s=>s.status==='Completed').map(s=>new Intl.DateTimeFormat('sv-SE',{timeZone:'America/Chicago'}).format(new Date(s.scheduled_at))+':'+s.shift)).size;
 const qualification=signoffs.find(s=>s.staff_id===staffId&&s.training_position_id===position.id&&s.active);
 const qualified=!!qualification;
 const completed=qualified&&!qualification?.inherited_source?Math.max(recorded,position.target_shifts):recorded;
 return {completed,target:position.target_shifts,remaining:qualified?0:Math.max(0,position.target_shifts-completed),scheduled:rows.filter(s=>s.status==='Scheduled').length,started:rows.length>0};
}

export type TrainingSignoff={origin?:'training'|'experience'|'migration'|'leadership';inherited_source?:'GM'|'sSHL';id:string;staff_id:string;training_position_id:string;active:boolean;created_by:string;created_at:string;version:number};

export function trainingBadge(staffId:string,position:TrainingPosition,sessions:ProgressSession[],signoffs:TrainingSignoff[]){
 const progress=trainingProgress(staffId,position,sessions);
 const signoff=signoffs.find(s=>s.staff_id===staffId&&s.training_position_id===position.id&&s.active);
 const trained=!!signoff;
 return {color:trained?'teal':progress.scheduled>0||progress.completed>0?'blue':'red',text:`${position.name}: ${trained?(signoff?.inherited_source?`Qualified through ${signoff.inherited_source}`:'Trained'):`${progress.completed}/${progress.target} Shifts`}`};
}
