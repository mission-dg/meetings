export type Profile={id:string;name:string;active:boolean;is_gm:boolean;is_admin:boolean};
export type Employee={id:string;first_name:string;last_name:string;department:'FOH'|'BOH';active:boolean;priority:boolean};
export type Meeting={id:string;staff_id:string;manager_id:string;created_by:string;type:'Routine'|'Special';scheduled_at:string;status:'Scheduled'|'Completed'|'Cancelled'|'Missed';completed_on:string|null;version:number};
export type Note={id:string;meeting_id:string;body:string;created_by:string;updated_at:string;version:number};
export type Request={id:string;staff_id:string;created_by:string;requested_on:string;status:'Open'|'Resolved'|'Withdrawn';meeting_id:string|null;version:number};
export type Data={profiles:Profile[];staff:Employee[];meetings:Meeting[];notes:Note[];requests:Request[]};
export const emptyData:Data={profiles:[],staff:[],meetings:[],notes:[],requests:[]};
export const zone='America/Chicago';
export function today(){return new Intl.DateTimeFormat('sv-SE',{timeZone:zone}).format(new Date())}
export function addMonths(day:string,n:number){const [y,m,d]=day.split('-').map(Number),t=new Date(Date.UTC(y,m-1+n,1));const last=new Date(Date.UTC(t.getUTCFullYear(),t.getUTCMonth()+1,0)).getUTCDate();return `${t.getUTCFullYear()}-${String(t.getUTCMonth()+1).padStart(2,'0')}-${String(Math.min(d,last)).padStart(2,'0')}`}
export function labels(p:Employee,d:Data,day=today()){const last=d.meetings.filter(m=>m.staff_id===p.id&&m.status==='Completed'&&m.completed_on&&m.completed_on<=day).map(m=>m.completed_on!).sort().at(-1);const due=last?addMonths(last,6):null;return {last,due,needs:p.active&&(!due||due<=day),priority:p.active&&(p.priority||!!due&&due<day),requested:p.active&&d.requests.some(r=>r.staff_id===p.id&&r.status==='Open')}}
export function displayTime(value:string){return new Intl.DateTimeFormat('en-US',{timeZone:zone,month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}).format(new Date(value))}
