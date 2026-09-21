import {useEffect,useState} from 'react';
import {supabase} from './client';
import type {SchedulerData} from './scheduler';
type Account={staff_id:string;username:string;state:string;expires_at?:string};
export function UsernameAccounts({data,preview,reload}:{data:SchedulerData;preview:boolean;reload:()=>Promise<void>}){
 const [allowed,setAllowed]=useState(false),[accounts,setAccounts]=useState<Account[]>([]),[busy,setBusy]=useState(false),[error,setError]=useState(''),[credentials,setCredentials]=useState<{username:string;temporary_password:string}|null>(null);
 const [staff,setStaff]=useState(''),[username,setUsername]=useState('');
 async function refresh(){
  if(preview){setAllowed(data.self.is_admin);return}
  const profile=await supabase!.from('manager_profiles').select('is_admin,is_gm,active').eq('id',data.self.id).single();
  const permitted=!!profile.data?.active&&(profile.data.is_admin||profile.data.is_gm);setAllowed(permitted);
  if(permitted){const r=await supabase!.rpc('username_account_list');if(r.error)setError(r.error.message);else setAccounts(r.data)}
 }
 useEffect(()=>{void refresh()},[data.self.id,preview]);
 async function create(staffId:string,user:string){
  if(busy)return;if(preview){setError('Disconnected demo: no accounts or passwords are created.');return}
  setBusy(true);setError('');setCredentials(null);
  try{
   const r=await supabase!.functions.invoke('manage-accounts',{body:{action:'create_username',staff_id:staffId,username:user,submission:crypto.randomUUID()}});
   if(r.error){let message='Account service unavailable. Refresh the list before retrying.';try{message=(await r.error.context.json()).error||message}catch{}throw Error(message)}
   if(r.data.error)throw Error(r.data.error);
   setCredentials(r.data);setStaff('');setUsername('');await refresh();await reload();
  }catch(e){setError((e as Error).message);await refresh()}finally{setBusy(false)}
 }
 if(!allowed)return null;
 return <section className="panel scheduler-card"><h2>Username accounts</h2><p>Create an employee login without an email address. IT and the GM can use this tool. Accounts start with employee access; IT can change roles after activation.</p>
 <form onSubmit={e=>{e.preventDefault();void create(staff,username)}}><fieldset disabled={busy}><div className="form-grid"><label>Employee<select required value={staff} onChange={e=>setStaff(e.target.value)}><option value="">Choose an employee</option>{data.people.filter(p=>p.staff_id&&p.active&&!accounts.some(a=>a.staff_id===p.staff_id)&&!data.accounts.some(a=>a.staff_id===p.staff_id)).map(p=><option key={p.id} value={p.staff_id}>{p.name}</option>)}</select></label><label>Username<input required minLength={3} maxLength={32} pattern="[a-zA-Z0-9][a-zA-Z0-9._\-]{2,31}" autoComplete="off" autoCapitalize="none" value={username} onChange={e=>setUsername(e.target.value)} placeholder="alex.lane"/></label></div><p className="muted">3–32 characters: letters, numbers, dots, underscores or hyphens. Usernames ignore capitalization.</p><button className="primary">{busy?'Creating…':'Create username account'}</button></fieldset></form>
 {error&&<p className="error" role="alert">{error}</p>}
 {credentials&&<section className="notice" role="status"><h3>Share these details privately</h3><p>Username: <strong>{credentials.username}</strong></p><label>Temporary password<input readOnly value={credentials.temporary_password} autoComplete="off" onFocus={e=>e.currentTarget.select()}/></label><p>This password is shown only now. The employee must sign in and change it within seven days. No email was sent.</p><button onClick={()=>setCredentials(null)}>Hide password</button></section>}
 {accounts.map(a=><div className="person-row" key={a.staff_id}><div className="grow"><strong>{data.people.find(p=>p.staff_id===a.staff_id)?.name||'Former employee'}</strong><small>{a.username} · {a.state==='Activated'?'Activated':a.state==='Ready'?'Awaiting first sign-in':'Setup needs completion'}</small></div>{a.state!=='Activated'&&<button disabled={busy} onClick={()=>{if(confirm('Reissue the temporary password for '+a.username+'? The previous temporary password will stop working.'))void create(a.staff_id,a.username)}}>Reissue temporary password</button>}</div>)}
 </section>;
}
