import type {Workspace,WorkspaceSession,SchedulerData} from './scheduler.ts';
export const workspaceLabels:Record<Workspace,string>={employee:'Employee View',manager:'Manager View',it:'IT View'};
export const managementGroups:[string,[string,string][]][]=[
 ['Daily work',[['home','Overview'],['schedule','Schedule'],['requests','Requests & availability']]],
 ['People',[['directory','Staff directory'],['training','Training'],['staffMeetings','Staff meetings'],['oneOnOnes','1:1s']]],
 ['Operations',[['announcements','Announcements'],['logbook','Manager logbook'],['documents','Documents'],['reports','Reports'],['labor','Labor planning']]],
 ['Administration',[['accounts','Accounts & access'],['audit','Change history'],['settings','Settings']]],
 ['', [['help','Help']]]
];
export const workspacePages:Record<Workspace,[string,string][]>= {
 employee:[['home','Today'],['schedule','Schedule'],['requests','Requests & availability'],['announcements','Updates'],['more','More']],
 manager:managementGroups.flatMap(([,pages])=>pages),it:managementGroups.flatMap(([,pages])=>pages)
};
export function canonicalPage(page:string){return ({availability:'requests',meetings:'oneOnOnes',administration:'accounts',staff:'directory',trainingProgress:'training',admin:'accounts'} as Record<string,string>)[page]||page}
export const employeeMore:[string,string][]=[['staffMeetings','Staff meetings'],['training','Training'],['directory','Team directory'],['documents','Documents'],['profile','My profile & calendar'],['settings','Settings'],['help','Help']];
export function allowedPage(workspace:Workspace,page:string){return (workspace!=='employee'&&page==='gmRequests')||[...workspacePages[workspace],...(workspace==='employee'?employeeMore:[])].some(([id])=>id===page)}
export function chooseWorkspace(session:WorkspaceSession,preferred:string|null):Workspace{if(preferred==='manager'&&session.views.includes('it'))return 'it';return session.views.includes(preferred as Workspace)?preferred as Workspace:session.views[0]}
// Used only by the disconnected demo. Production uses the server's matching projection.
export function projectDemo(data:SchedulerData,workspace:Workspace):SchedulerData {
 if(workspace!=='employee')return {...data,workspace};
 const sid=data.self.staff_id;
 return {...data,workspace,meeting_due:[],meeting_managers:[],meeting_requests:[],shift_meetings:data.shift_meetings?.filter(m=>m.staff_id===sid&&m.timing_mode==='during_shift'&&(!m.schedule_revision_id||data.published.some(p=>p.revision_id===m.schedule_revision_id))),self:{...data.self,is_manager:false,is_admin:false,is_gm:false},week:{...data.week,draft:null},accounts:[],service:{},audit:[],releases:[],published:data.published.map(w=>({...w,shifts:w.shifts.map(({qualification_reason,...s})=>s)})),training:data.training.filter(t=>(data.self.is_ca||t.staff_id===sid||t.trainer_id===sid)&&(!t.schedule_revision_id||data.published.some(p=>p.revision_id===t.schedule_revision_id))),signoffs:data.signoffs.filter(s=>data.self.is_ca||s.staff_id===sid),requests:data.requests.filter(q=>q.created_by===data.self.id||q.payload.recipient===data.self.person_id||q.kind==='Offer'&&q.status==='Pending').map(q=>q.created_by===data.self.id?q:({...q,reason:undefined,response:undefined}))};
}
