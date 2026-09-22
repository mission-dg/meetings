import {useUnsavedChanges} from './useUnsavedChanges';
import {useState,type ReactNode} from 'react';
import {SchedulerAccounts} from './SchedulerAccounts';
import type {SchedulerData,Act} from './scheduler';
import {leadershipPerson} from './accountGroups';
export function AccountsHub({data,act,busy,reload,preview,shlControls}:{data:SchedulerData;act:Act;busy:boolean;reload:()=>Promise<void>;preview:boolean;shlControls:ReactNode}){
 const canLeave=useUnsavedChanges();
 const [tab,setTab]=useState(new URLSearchParams(location.search).get('accountTab')==='shl'?'shl':'teammates');
 const people=data.people.filter(p=>Boolean(leadershipPerson(data,p.id))===(tab==='shl'));
 const scoped={...data,people,accounts:data.accounts.filter(a=>people.some(p=>p.staff_id===a.staff_id))};
 return <><nav className="profile-tabs" aria-label="Account groups">{[['teammates','Teammate accounts'],['shl','SHL accounts']].map(([id,label])=><button key={id} aria-current={tab===id?'page':undefined} onClick={()=>{if(!canLeave())return;setTab(id);const u=new URL(location.href);u.searchParams.set('accountTab',id);history.replaceState(null,'',u)}}>{label}</button>)}</nav><p>{tab==='shl'?'SHL logins, schedule categories, roster inclusion, and authorized GM/IT access controls.':'Standard teammate logins and permissions. SHL accounts are managed in their own tab.'}</p><SchedulerAccounts key={tab} data={scoped} act={act} busy={busy} reload={reload} preview={preview}/>{tab==='shl'&&shlControls}</>
}
