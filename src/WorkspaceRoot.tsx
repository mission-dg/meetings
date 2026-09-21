import {type UsernameStatus} from './username';
import {useCallback,useEffect,useRef,useState,type ReactNode} from 'react';
import type {Session} from '@supabase/supabase-js';
import {CalendarDays,Users,MessageSquare,BookOpen,LogOut,RefreshCw,ShieldCheck,ClipboardList,ArrowLeft,Clock} from 'lucide-react';
import {supabase,configured} from './client';
import {LoginForm,PasswordForm} from './AuthForms';
import {ScheduleBoard} from './ScheduleBoard';
import {ScheduleRequests} from './ScheduleRequests';
import {Announcements} from './Announcements';
import {SchedulerAccounts} from './SchedulerAccounts';
import {SchedulerTraining} from './SchedulerTraining';
import {type SchedulerData,type Act,type LinkedTraining,type ScheduleRequest,weekOf,addDays,centralInstant,localFields} from './scheduler';
import {Modal,TrainingForm} from './SchedulerForms';
import {displayTime,today} from './domain';
import {approvedAvailability} from './availability';
import './scheduler.css';
import './workspaces.css';
import {WorkspaceHome,Commitments} from './WorkspaceHome';
import {workspaceLabels,workspacePages,employeeMore,allowedPage,chooseWorkspace,projectDemo} from './workspaces';
import type {Workspace,WorkspaceSession} from './scheduler';
import {Operations} from './Operations';
import {useUnsavedChanges} from './useUnsavedChanges';
const preview=import.meta.env.DEV&&new URLSearchParams(location.search).get('preview')==='1';
function demo(week:string,role:string,requests:ScheduleRequest[]=[]):SchedulerData{
 const people=[{id:'s:Alex.L',staff_id:'Alex.L',name:'Alex Lane',group:'FOH',active:true,on_roster:true,is_trainer:true,is_ca:true,primary_job_id:'gsr'},{id:'s:Casey.W',staff_id:'Casey.W',name:'Casey Williams',group:'FOH',active:true,on_roster:true,is_trainer:false,primary_job_id:'gsr'},{id:'s:Jordan.D',staff_id:'Jordan.D',name:'Jordan Davis',group:'BOH',active:true,on_roster:true,is_trainer:false},{id:'m:demo',name:'Morgan Hayes',group:'SHL',active:true,on_roster:true,is_trainer:false}];
 const shifts=people.flatMap((p,i)=>[1,3,5].map((d,j)=>({id:`demo-${i}-${d}`,person_id:p.id,start:centralInstant(addDays(week,d)+'T'+(j===1?'14:00':'11:00')),end:centralInstant(addDays(week,d)+'T'+(j===1?'21:00':'17:00')),slot:j===1?2:1,job_id:p.group==='SHL'?null:p.group==='BOH'?'line':'gsr',qualification_reason:'Supervised learning'})));
 return {self:{id:['manager','it'].includes(role)?'demo':role==='ca'?'ca':'employee',person_id:['manager','it'].includes(role)?'m:demo':role==='ca'?'s:Alex.L':'s:Casey.W',staff_id:['manager','it'].includes(role)?undefined:role==='ca'?'Alex.L':'Casey.W',name:['manager','it'].includes(role)?'Morgan Hayes':role==='ca'?'Alex Lane':'Casey Williams',is_manager:['manager','it'].includes(role),is_ca:role==='ca',is_admin:role==='it'},week:{start:week,published_id:'demo-published',draft:null},people,published:[{week,revision_id:'demo-published',shifts}],jobs:[{id:'gsr',name:'GSR',department:'FOH',active:true,target_shifts:4},{id:'expo',name:'EXPO',department:'FOH',active:true,target_shifts:4},{id:'drl',name:'DRL',department:'FOH',active:true,target_shifts:4},{id:'line',name:'Line',department:'BOH',active:true,target_shifts:4},{id:'prep',name:'Prep',department:'BOH',active:true,target_shifts:4},{id:'catering',name:'Catering',department:'Catering',active:true,target_shifts:4}],training:[{id:'demo-training',staff_id:'Casey.W',trainer_id:'Alex.L',training_position_id:'gsr',scheduled_at:centralInstant(addDays(week,1)+'T11:00'),ends_at:centralInstant(addDays(week,1)+'T15:00'),shift:1,status:'Scheduled',version:1,created_by:'demo',work_shift_id:'demo-1-1',trainer_shift_id:'demo-0-1'}],signoffs:[],appointments:[],requests:requests.filter(q=>['manager','it'].includes(role)||q.created_by===(role==='ca'?'ca':'employee')),announcements:[{id:'demo-announcement',title:'Ready for a great week.',body:'Check your schedule and training assignments. Submit any availability changes through Requests so your managers can review them.',groups:[],created_by:'demo',author:'Morgan Hayes',active:true,version:1,created_at:new Date().toISOString(),read:false}],notifications:[],accounts:[],service:{email_verified:false,last_worker_at:new Date().toISOString()},releases:[],audit:[]};
}
export function WorkspaceRoot({legacy}:{legacy:(back:(view?:string)=>void,authors:Record<string,string>)=>ReactNode}){
 const [session,setSession]=useState<Session|null>(null),[checking,setChecking]=useState(!preview),[week,setWeek]=useState(weekOf()),[role,setRole]=useState('it'),[workspace,setWorkspace]=useState<Workspace|null>(null),[access,setAccess]=useState<WorkspaceSession|null>(null),[data,setData]=useState<SchedulerData|null>(null),[error,setError]=useState(''),[notice,setNotice]=useState(''),[busy,setBusy]=useState(false),[view,setView]=useState(new URLSearchParams(location.search).get('page')||'home'),[old,setOld]=useState(false),[password,setPassword]=useState(()=>['recovery','invite'].includes(new URLSearchParams(location.hash.slice(1)).get('type')||'')),[training,setTraining]=useState<{revision?:string;initial?:LinkedTraining}|null>(null);
 const previewRequests=useRef<ScheduleRequest[]>([{id:'demo-approved-hours',kind:'Availability',person_id:'s:Casey.W',created_by:'employee',status:'Approved',version:2,created_at:addDays(today(),-15)+'T12:00:00Z',decided_at:addDays(today(),-14)+'T12:00:00Z',decided_name:'Morgan Hayes',payload:{effective:addDays(today(),-14),days:Array.from({length:7},(_,i)=>i===0?[[690,1200]]:[[660,1260]])}}]);
 const canLeave=useUnsavedChanges();
 const [usernameStatus,setUsernameStatus]=useState<UsernameStatus|null>(null);
 const serial=useRef(0),pending=useRef<{key:string;id:string}|null>(null),sessionId=useRef<string|undefined>(undefined);
 const load=useCallback(async()=>{
  const token=++serial.current;
  if(preview){const raw=demo(week,role,previewRequests.current),info:WorkspaceSession={id:raw.self.id,name:raw.self.name,person_id:raw.self.person_id,is_ca:raw.self.is_ca,views:role==='it'?['it','manager','employee']:role==='manager'?['manager','employee']:['employee']};const selected=chooseWorkspace(info,workspace);setAccess(info);setWorkspace(selected);setData(projectDemo(raw,selected));return}
  if(!supabase||!session)return;
  const loginStatus=await supabase.rpc('username_account_status');if(token!==serial.current)return;
  if(loginStatus.error){setData(null);setError('Account check unavailable. Refresh or contact IT.');throw loginStatus.error}
  setUsernameStatus(loginStatus.data);
  if(loginStatus.data?.required){setData(null);setOld(false);setPassword(true);return}
  const auth=await supabase.rpc('workspace_session');if(token!==serial.current)return;
  if(auth.error){setData(null);setError(auth.error.message);throw auth.error}
  const info=auth.data as WorkspaceSession;
  let stored:string|null=null;try{stored=localStorage.getItem('shift:view:'+info.id)}catch{}
  const requested=workspace||new URLSearchParams(location.search).get('workspace')||stored;
  const selected=chooseWorkspace(info,requested);
  if(selected!==workspace){setData(null);setOld(false);setTraining(null)}
  const result=await supabase.rpc('workspace_read',{p_week:week,p_view:selected});if(token!==serial.current)return;
  if(result.error){setData(null);setError(result.error.message);throw result.error}
  setAccess(info);setWorkspace(selected);setData(result.data as SchedulerData);setError('');try{localStorage.setItem('shift:view:'+info.id,selected)}catch{}
 },[session?.user.id,week,workspace,role]);
 useEffect(()=>{if(preview){setChecking(false);return}if(!supabase){setChecking(false);return}supabase.auth.getSession().then(({data})=>{sessionId.current=data.session?.user.id;setSession(data.session);setChecking(false)});const {data:l}=supabase.auth.onAuthStateChange((event,s)=>{if(event==='PASSWORD_RECOVERY')setPassword(true);if(sessionId.current!==s?.user.id){serial.current++;setData(null);setOld(false);setTraining(null);setError('');setWorkspace(null);setAccess(null);setUsernameStatus(null);pending.current=null}sessionId.current=s?.user.id;setSession(s)});return()=>l.subscription.unsubscribe()},[]);
 useEffect(()=>{if(preview||session)void load().catch(()=>{})},[session?.user.id,load]);
 useEffect(()=>{if(workspace&&!allowedPage(workspace,view))setView('home')},[workspace,view]);
 useEffect(()=>{if(!session||preview)return;const refresh=()=>{if(document.visibilityState==='visible')void load().catch(()=>{})};window.addEventListener('focus',refresh);const timer=setInterval(refresh,60000);return()=>{clearInterval(timer);window.removeEventListener('focus',refresh)}},[load,session]);
 async function signOut(){await supabase?.auth.signOut();setData(null);setSession(null);setOld(false);setPassword(false);setWorkspace(null);setAccess(null)}
 const act:Act=async(action,payload)=>{if(busy)throw Error('A save is already in progress.');setBusy(true);setError('');setNotice('');try{if(preview){setNotice('Disconnected preview: no live records changed.');
 if(data&&(action==='request'&&payload.kind==='Availability'||['decide','withdraw','revoke'].includes(action)&&previewRequests.current.some(q=>q.id===payload.id))){
  let requests=previewRequests.current;
  if(action==='request')requests=[{id:crypto.randomUUID(),kind:'Availability',person_id:data.self.person_id,created_by:data.self.id,status:'Pending',version:1,created_at:new Date().toISOString(),payload:payload.details as ScheduleRequest['payload'],reason:String(payload.reason||'')},...requests];
  else {
   const q=requests.find(q=>q.id===payload.id)!;
   if(q.version!==payload.version)throw Error('This request changed. Reload.');
   if(action==='withdraw'?q.created_by!==data.self.id:!data.self.is_manager||q.created_by===data.self.id)throw Error('Another manager must decide this request.');
   requests=requests.map(q=>q.id===payload.id?{...q,status:action==='withdraw'||action==='revoke'?'Withdrawn':String(payload.decision),version:q.version+1,...(action==='withdraw'?{}:{response:String(payload.response||''),decided_at:new Date().toISOString(),decided_name:data.self.name})}:q);
   if(action==='decide'&&payload.decision==='Approved'||action==='revoke'){
    for(const shift of data.published.flatMap(w=>w.shifts).filter(s=>s.person_id===q.person_id&&new Date(s.end)>new Date())){
     const start=localFields(shift.start),end=localFields(shift.end);
     for(let day=start.slice(0,10);day<=end.slice(0,10);day=addDays(day,1)){
      const lo=day===start.slice(0,10)?Number(start.slice(11,13))*60+Number(start.slice(14)):0,hi=day===end.slice(0,10)?Number(end.slice(11,13))*60+Number(end.slice(14)):1440;
      const approved=approvedAvailability(requests,q.person_id,day);
      let coveredTo=lo;for(const [a,b] of approved?.payload.days?.[new Date(day+'T12:00:00Z').getUTCDay()]||[]){if(a<=coveredTo&&b>coveredTo)coveredTo=b}
      if(hi>lo&&approved&&coveredTo<hi)throw Error('Resolve conflicting published shifts before approving: '+day);
     }
    }
   }
  }
  previewRequests.current=requests;setData({...data,requests:requests.filter(q=>data.self.is_manager||q.created_by===data.self.id)});return {};
 }
 if(action==='draft'&&data){setData({...data,week:{...data.week,draft:{id:'demo-draft',version:1,state:'Draft',base_id:data.week.published_id,shifts:data.published.find(p=>p.week===week)?.shifts||[],release_at:null,release_name:'Morgan Hayes',error:null}}})}else if(data?.week.draft&&['save','queue','unqueue','release'].includes(action)){const d=data.week.draft;if(action==='release')setData({...data,published:[...data.published.filter(p=>p.week!==week),{week,revision_id:d.id,shifts:d.shifts}],week:{...data.week,draft:null,published_id:d.id}});else setData({...data,week:{...data.week,draft:{...d,version:d.version+1,shifts:action==='save'?payload.shifts as typeof d.shifts:d.shifts,state:action==='queue'?'Queued':'Draft',release_at:action==='queue'?String(payload.release_at):null}}})}return {issues:[],state:action==='release'?'Published':'Draft'}}const key=JSON.stringify([action,payload]);if(pending.current?.key!==key)pending.current={key,id:crypto.randomUUID()};const {data:result,error:e}=await supabase!.rpc('scheduler_action',{p_action:action,p_payload:payload,p_submission:pending.current.id});if(e)throw Error(e.message);pending.current=null;setNotice(result.state==='Attention'?'Saved; release needs attention.':'Saved.');try{await load()}catch{setNotice('Saved; the workspace needs refreshing. Do not submit again.')}return result}catch(e){setError((e as Error).message);throw e}finally{setBusy(false)}};
 if(checking)return <div className="loading">Opening your workspace…</div>;
 if(!session&&!preview)return <div className="login"><div className="login-story"><div className="brand"><span className="brand-icon">M</span><span>MISSION BBQ<small>TEAM WORKSPACE</small></span></div><div><p className="eyebrow">TOGETHER, EVERY SHIFT</p><h1>Your team.<br/>Your next shift.</h1><p>Schedules, training, and the conversations that keep us connected.</p></div><small>Private access for your restaurant team.</small></div><section className="login-form"><p className="eyebrow">TEAM WORKSPACE</p><h2>Welcome back.</h2><p className="muted">Sign in with your username or email and password.</p>{configured?<LoginForm/>:<p>The workspace is being connected.</p>}</section></div>;
 if(session&&(password||usernameStatus?.required))return <PasswordForm email={usernameStatus?.username||session.user.email||''} required={usernameStatus?.required} ready={!usernameStatus?.required||usernameStatus.ready} onClose={()=>{if(usernameStatus?.required)void signOut();else setPassword(false)}} onSaved={()=>{setUsernameStatus(null);setPassword(false);setNotice('Password saved.');void load().catch(()=>{})}}/>;
 if(!data)return <div className="loading"><ShieldCheck/><h2>{error?'Workspace needs attention':'Opening your workspace…'}</h2><p>{error}</p><button onClick={()=>void load().catch(()=>{})}>Refresh</button><button onClick={()=>void signOut()}>Sign out</button></div>;
 if(!workspace||!access)return <div className="loading">Opening your workspace…</div>;
 function navigate(next:string){if(busy||!canLeave())return;if(next==='meetings'||next==='administration'){if(workspace==='employee')return;setOld(true);return}if(!allowedPage(workspace!,next))next='home';setView(next);setNotice('');setError('');const url=new URL(location.href);url.searchParams.set('workspace',workspace!);url.searchParams.set('page',next);history.replaceState(null,'',url)}
 function switchWorkspace(next:Workspace){if(busy||!access!.views.includes(next)||!canLeave())return;serial.current++;setData(null);setOld(false);setTraining(null);setView('home');setError('');setNotice('');setWorkspace(next);try{localStorage.setItem('shift:view:'+access!.id,next)}catch{}const url=new URL(location.href);url.searchParams.set('workspace',next);url.searchParams.delete('page');history.replaceState(null,'',url)}
 if(old&&workspace!=='employee')return legacy(()=>{setView('home');setOld(false);void load().catch(()=>{})},Object.fromEntries(data.accounts.map(a=>[a.id,data.people.find(p=>p.staff_id===a.staff_id)?.name||'Former teammate'])));
 const pages=workspacePages[workspace],pageTitle=[...pages,...employeeMore].find(([id])=>id===view)?.[1]||'Home';
 const unread=data.announcements.filter(a=>a.active&&!a.read).length+data.notifications.filter(n=>!n.read_at).length;
 const navigation=pages.map(([id,title])=><button key={id} className={view===id?'selected':''} aria-current={view===id?'page':undefined} onClick={()=>navigate(id)}>{title}{id==='announcements'&&unread>0&&<span className="nav-count">{unread}</span>}</button>);
 const switcher=<label className="workspace-switcher"><span>Workspace</span><select aria-label="Workspace view" value={workspace} disabled={busy} onChange={e=>switchWorkspace(e.target.value as Workspace)}>{access.views.map(v=><option value={v} key={v}>{workspaceLabels[v]}</option>)}</select></label>;
 return <div className={'shell scheduler-shell workspace-'+workspace}>
 {workspace!=='employee'&&<aside><div className="brand"><span className="brand-icon">M</span><span>MISSION BBQ<small>{workspace==='it'?'SYSTEM ADMINISTRATION':'MANAGER WORKSPACE'}</small></span></div>{switcher}<nav aria-label={workspaceLabels[workspace]+' navigation'}>{navigation}</nav><div className="sidebar-bottom"><p>{access.name}</p><button onClick={()=>{if(canLeave())setPassword(true)}}>Change password</button><button onClick={()=>{if(canLeave())void signOut()}}>Sign out</button></div></aside>}
 <main><header className="topbar"><div className="workspace-heading">{workspace==='employee'?<strong>MISSION BBQ <span>My Shift</span></strong>:<strong>{workspaceLabels[workspace]}</strong>}<small>{access.name}</small></div><div className="actions">{workspace==='employee'&&switcher}<button aria-label="Refresh workspace" disabled={busy} onClick={()=>void load().catch(()=>{})}><RefreshCw size={18}/></button>{workspace==='employee'&&<button onClick={()=>{if(canLeave())void signOut()}}>Sign out</button>}</div></header>
 {workspace==='employee'&&<nav className="employee-navigation" aria-label="Employee navigation">{navigation}</nav>}
 <div className="content" key={workspace}><p className="notice pilot-notice">Shift pilot · Schedulefly remains the official schedule until your manager announces the cutover.</p>
 {preview&&<div className="preview-banner">DISCONNECTED DEMO · Fictional people · No live changes or emails<select aria-label="Demo account" value={role} onChange={e=>{if(!canLeave())return;setRole(e.target.value);setWorkspace(null);setView('home')}}><option value="it">IT demo account</option><option value="manager">Manager demo account</option><option value="ca">CA demo account</option><option value="employee">Employee demo account</option></select></div>}
 <div className="page-title"><div><p className="eyebrow">{today()} · CENTRAL TIME</p><h1>{view==='home'?workspace==='employee'?'Your day, at a glance.':workspace==='it'?'System overview.':'Ready for today.':pageTitle}</h1></div>{view==='home'&&workspace==='manager'&&<button className="primary" onClick={()=>navigate('schedule')}>Build the schedule</button>}</div>
 {notice&&<p className="success" role="status">{notice}</p>}{error&&!training&&<p className="error" role="alert">{error}</p>}
 {view==='home'&&<WorkspaceHome data={data} workspace={workspace} go={navigate} preview={preview}/>}
 {view==='more'&&<div className="more-grid">{employeeMore.map(([id,title])=><button key={id} onClick={()=>navigate(id)}>{title}<span>→</span></button>)}<button onClick={()=>{if(canLeave())setPassword(true)}}>Change password</button></div>}
 {view==='schedule'&&<><ScheduleBoard data={data} week={week} setWeek={setWeek} act={act} busy={busy} onTraining={revision=>setTraining({revision})}/><Commitments data={data}/></>}
 {view==='availability'&&<ScheduleRequests key="availability" data={data} act={act} busy={busy} availabilityOnly/>}
 {view==='requests'&&<ScheduleRequests key="requests" data={data} act={act} busy={busy}/>}
 {view==='announcements'&&<Announcements data={data} act={act} busy={busy}/>}
 {(view==='accounts'||view==='audit')&&workspace!=='employee'&&<SchedulerAccounts data={data} act={act} busy={busy} reload={load} preview={preview} auditOnly={view==='audit'}/>}
 {view==='training'&&<SchedulerTraining data={data} act={act} busy={busy} onReload={load} preview={preview} onSchedule={()=>setTraining({})} onEdit={initial=>setTraining({initial,revision:initial.schedule_revision_id===data.week.draft?.id?initial.schedule_revision_id:undefined})}/>}
 {['logbook','directory','documents','reports','labor','profile','help'].includes(view)&&<Operations key={workspace+view} page={view} workspace={workspace} data={data} preview={preview}/>}
 <footer>MISSION BBQ · {workspaceLabels[workspace]}<span>America/Chicago · {workspace==='employee'?'Published schedules':'Pilot · Confirm the official schedule with your manager'}</span></footer>
 </div></main>{training&&<Modal title={training.initial?'Edit training':'Schedule training'} busy={busy} onClose={()=>{setTraining(null);setError('')}}><TrainingForm data={data} revision={training.revision} initial={training.initial} busy={busy} error={error} onSave={p=>act('training_save',{...p,...(training.initial?{id:training.initial.id,version:training.initial.version}:{})}).then(()=>setTraining(null)).catch(()=>{})}/></Modal>}</div>
}
