import type {Workspace} from './scheduler';
import {employeeGuides} from './helpGuides';
import {useState} from 'react';
import type {SchedulerData} from './scheduler';
import {guides} from './helpGuides';
export function HelpCenter({data,go,context='',workspace='manager'}:{workspace?:Workspace;data:SchedulerData;go:(page:string)=>void;context?:string}){
 const [search,setSearch]=useState('');const initial=new URLSearchParams(location.search).get('article')||context||'';
 const [article,setArticle]=useState(guides.some(g=>g.id===initial)?initial:'');
 const available=(workspace==='employee'?employeeGuides:guides).filter(g=>!g.restricted||data.self.is_admin||data.self.is_gm);
 const found=available.filter(g=>(g.title+' '+g.keywords+' '+g.steps.join(' ')+' '+g.recovery).toLowerCase().includes(search.toLowerCase()));
 function select(id:string){setArticle(id);const url=new URL(location.href);url.searchParams.set('article',id);history.replaceState(null,'',url)}
 return <section className="help-center"><label>Search Help<input type="search" value={search} onChange={e=>setSearch(e.target.value)} placeholder="Try release, qualifications, password, or CSV"/></label><p>Guidance for your authorized tools. Contact your store’s IT administrator for account-specific help.</p><div className="help-topics">{found.map(g=><button key={g.id} aria-expanded={article===g.id} onClick={()=>select(g.id)}>{g.title}</button>)}</div>{!found.length&&<p role="status">No matching guides. Try “schedule”, “training”, or “account”, or <button onClick={()=>setSearch('')}>show all topics</button>.</p>}{found.filter(g=>!!search||article===g.id||!article).map(g=><article className="panel scheduler-card" key={g.id}><h2>{g.title}</h2><p className="muted">{workspace==='employee'?'Employees':g.restricted?'GM / IT':'Authorized managers and IT'} · Existing permissions apply.</p><ol>{g.steps.map(step=><li key={step}>{step}</li>)}</ol><p className="notice">{g.recovery}</p>{(workspace==='employee'||g.page!=='profile')&&<button className="primary" onClick={()=>go(g.page)}>Open {g.page==='oneOnOnes'?'1:1s':g.page==='staffMeetings'?'Staff meetings':g.page==='requests'?'Approvals':g.page==='home'?'Overview':g.page}</button>}</article>)}</section>
}
