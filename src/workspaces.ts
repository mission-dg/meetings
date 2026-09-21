import type {Workspace,WorkspaceSession,SchedulerData} from './scheduler.ts';
export const workspaceLabels:Record<Workspace,string>={employee:'Employee View',manager:'Manager View',it:'IT View'};
export const workspacePages:Record<Workspace,[string,string][]>= {
 employee:[['home','Today'],['schedule','Schedule'],['requests','Requests'],['announcements','Updates'],['more','More']],
 manager:[['home','Daily brief'],['schedule','Schedule builder'],['requests','Approvals'],['availability','Team availability'],['training','Training'],['meetings','Meetings & staff'],['logbook','Manager logbook'],['announcements','Announcements'],['directory','Directory'],['documents','Documents'],['reports','Reports'],['labor','Labor planning'],['accounts','Employee invitations']],
 it:[['home','System overview'],['accounts','Accounts & access'],['administration','Staff & permissions'],['directory','Directory'],['audit','Change history'],['help','Settings & help']]
};
export const employeeMore:[string,string][]=[['availability','My availability'],['training','Training'],['directory','Team directory'],['documents','Documents'],['profile','My profile & calendar'],['help','Help']];
export function allowedPage(workspace:Workspace,page:string){return [...workspacePages[workspace],...(workspace==='employee'?employeeMore:[])].some(([id])=>id===page)}
export function chooseWorkspace(session:WorkspaceSession,preferred:string|null):Workspace{return session.views.includes(preferred as Workspace)?preferred as Workspace:session.views[0]}
// Used only by the disconnected demo. Production uses the server's matching projection.
export function projectDemo(data:SchedulerData,workspace:Workspace):SchedulerData {
 if(workspace!=='employee')return {...data,workspace};
 const sid=data.self.staff_id;
 return {...data,workspace,self:{...data.self,is_manager:false,is_admin:false},week:{...data.week,draft:null},accounts:[],service:{},audit:[],releases:[],published:data.published.map(w=>({...w,shifts:w.shifts.map(({qualification_reason,...s})=>s)})),training:data.training.filter(t=>(data.self.is_ca||t.staff_id===sid||t.trainer_id===sid)&&(!t.schedule_revision_id||data.published.some(p=>p.revision_id===t.schedule_revision_id))),signoffs:data.signoffs.filter(s=>data.self.is_ca||s.staff_id===sid),requests:data.requests.filter(q=>q.created_by===data.self.id||q.payload.recipient===data.self.person_id||q.kind==='Offer'&&q.status==='Pending').map(q=>q.created_by===data.self.id?q:({...q,reason:undefined,response:undefined}))};
}
