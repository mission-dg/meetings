import {useUnsavedChanges} from './useUnsavedChanges';
import {useState} from 'react';
import {CoverageSettings} from './CoverageSettings';
import type {SchedulerData} from './scheduler';
import {displayTime} from './domain';
export function SettingsPage({data,week,preview,reload,onPassword,go,training,system}:{data:SchedulerData;week:string;preview:boolean;reload:()=>Promise<void>;onPassword:()=>void;go:(page:string)=>void;training?:React.ReactNode;system?:React.ReactNode}){
 const canLeave=useUnsavedChanges();
 const [section,setSection]=useState(new URLSearchParams(location.search).get('section')||'account');
 const configure=data.self.is_admin||data.self.is_gm;
 const sections=[['account','My account'],...(configure?[['scheduling','Scheduling configuration']]:[]),...(data.self.is_admin?[['training','Training configuration'],['system','System & service']]:[]),['location','Location']];
 return <div><nav className="profile-tabs" aria-label="Settings sections">{sections.map(([id,label])=><button key={id} aria-current={section===id?'page':undefined} onClick={()=>{if(!canLeave())return;setSection(id);const url=new URL(location.href);url.searchParams.set('section',id);history.replaceState(null,'',url)}}>{label}</button>)}</nav>{section==='account'&&<section className="panel scheduler-card"><h2>My account</h2><p>{data.self.name}</p><button onClick={onPassword}>Change my password</button><p>Employee account permissions are managed separately.</p><button onClick={()=>go('accounts')}>Accounts & access</button></section>}{section==='scheduling'&&configure&&<><p>Configure actual service windows and staffing needs. Changes can require a new release review.</p><CoverageSettings week={week} data={data} preview={preview} onSaved={()=>void reload()}/></>}{section==='training'&&configure&&training}{section==='system'&&data.self.is_admin&&<><section className="panel scheduler-card"><h2>Release service</h2><p>{data.service.last_worker_at?'Last successful check: '+displayTime(data.service.last_worker_at):'Status unavailable — no successful check recorded.'}</p><button onClick={()=>void reload()}>Refresh status</button></section>{system}</>}{section==='location'&&<section className="panel scheduler-card"><h2>Downers Grove, Illinois</h2><p>Timezone: America/Chicago</p><p className="muted">Read-only pilot location. Other stores are not enabled.</p></section>}</div>
}
