import {useEffect,useState} from 'react';
import {supabase} from './client';
import type {SchedulerData} from './scheduler';
type Account={id:string;staff_id:string;username:string;state:string;expires_at?:string;version:number;role:string;active:boolean};
export function UsernameAccounts({data,preview,reload}:{data:SchedulerData;preview:boolean;reload:()=>Promise<void>}){
 const [allowed,setAllowed]=useState(false),[accounts,setAccounts]=useState<Account[]>([]),[busy,setBusy]=useState(false),[error,setError]=useState(''),[credentials,setCredentials]=useState<{username:string;temporary_password:string}|null>(null);
 const [staff,setStaff]=useState(''),[username,setUsername]=useState(''),[role,setRole]=useState('employee'),[editing,setEditing]=useState<Account|null>(null),[editName,setEditName]=useState('');
 async function refresh(){
  if(preview){setAllowed(data.self.is_admin);setAccounts([{id:'demo-login',staff_id:'Alex.L',username:'alex.lane',state:'Activated',version:1,role:'employee',active:true}]);return}
  const profile=await supabase!.from('manager_profiles').select('is_admin,is_gm,active').eq('id',data.self.id).single();
  const permitted=!!profile.data?.active&&(profile.data.is_admin||profile.data.is_gm);setAllowed(permitted);
  if(permitted){const r=await supabase!.rpc('username_account_list');if(r.error)setError(r.error.message);else setAccounts(r.data)}
 }
 useEffect(()=>{void refresh()},[data.self.id,preview]);
 async function create(staffId:string,user:string,target?:Account){
  if(busy)return;if(preview){setError('Disconnected demo: no accounts or passwords are created.');return}
  setBusy(true);setError('');setCredentials(null);
  try{
   const r=await supabase!.functions.invoke('manage-accounts',{body:{action:target?'reset_username':'create_username',id:target?.id,version:target?.version,staff_id:staffId,username:user,role,submission:crypto.randomUUID()}});
   if(r.error){let message='Account service unavailable. Refresh the list before retrying.';try{message=(await r.error.context.json()).error||message}catch{}throw Error(message)}
   if(r.data.error)throw Error(r.data.error);
   setCredentials(r.data);setStaff('');setUsername('');setRole('employee');setEditing(null);await refresh();await reload();
  }catch(e){setError((e as Error).message);await refresh()}finally{setBusy(false)}
 }
 if(!allowed)return null;
 return <section className="panel scheduler-card"><h2>Create an account</h2><p>GM and IT can create Employee or Manager accounts using a username and temporary password. No email address or invitation is needed.</p>
 <form onSubmit={e=>{e.preventDefault();void create(staff,username)}}><fieldset disabled={busy}><div className="form-grid"><label>Teammate<select required value={staff} onChange={e=>setStaff(e.target.value)}><option value="">Choose a teammate</option>{data.people.filter(p=>p.staff_id&&p.active&&!accounts.some(a=>a.staff_id===p.staff_id)&&!data.accounts.some(a=>a.staff_id===p.staff_id)).map(p=><option key={p.id} value={p.staff_id}>{p.name}</option>)}</select></label><label>Account type<select value={role} onChange={e=>setRole(e.target.value)}><option value="employee">Employee</option><option value="manager">Manager</option></select></label><label>Username<input required minLength={3} maxLength={32} pattern="[a-zA-Z0-9][a-zA-Z0-9._\-]{2,31}" autoComplete="off" autoCapitalize="none" value={username} onChange={e=>setUsername(e.target.value)} placeholder="alex.lane"/></label></div><p className="muted">3–32 characters: letters, numbers, dots, underscores or hyphens. Usernames ignore capitalization.</p><button className="primary">{busy?'Creating…':'Create account'}</button></fieldset></form>
 {error&&<p className="error" role="alert">{error}</p>}
 {credentials&&<section className="notice" role="status"><h3>Share these details privately</h3><p>Username: <strong>{credentials.username}</strong></p><label>Temporary password<input readOnly value={credentials.temporary_password} autoComplete="off" onFocus={e=>e.currentTarget.select()}/></label><p>This password is shown only now. They must sign in and change it within seven days. No email was sent.</p><button onClick={()=>setCredentials(null)}>Hide password</button></section>}
 <h3>Manage username accounts</h3><p className="muted">Changing a login generates a new temporary password, signs out existing sessions and preserves the person's records and role. Existing passwords cannot be viewed.</p>
 {accounts.map(a=><div className="person-row" key={a.id}><div className="grow"><strong>{data.people.find(p=>p.staff_id===a.staff_id)?.name||'Former teammate'}</strong><small>{a.username} · {a.role==='it'?'IT':a.role==='manager'?'Manager':'Employee'} · {!a.active?'Inactive':a.state==='Activated'?'Active':a.state==='Ready'?'Password change required':'Setup needs IT review'}</small></div>{a.id!==data.self.id&&<button disabled={busy||!a.active||a.state==='Reserved'} onClick={()=>{setEditing(a);setEditName(a.username);setCredentials(null)}}>Change username / reset password</button>}</div>)}
 {!accounts.length&&<p>No username accounts yet.</p>}
 {editing&&<form onSubmit={e=>{e.preventDefault();if(confirm('Replace the login credentials for '+editing.username+'? Their current password will stop working and they will need the new temporary password.'))void create(editing.staff_id,editName,editing)}}><h3>Change login for {data.people.find(p=>p.staff_id===editing.staff_id)?.name||editing.username}</h3><fieldset disabled={busy}><label>Username<input required minLength={3} maxLength={32} pattern="[a-zA-Z0-9][a-zA-Z0-9._\-]{2,31}" autoComplete="off" autoCapitalize="none" value={editName} onChange={e=>setEditName(e.target.value)}/></label><p>Keep the same username to reset only the password. A new temporary password will be shown once.</p><div className="actions"><button type="button" onClick={()=>setEditing(null)}>Cancel</button><button className="primary">Generate replacement login</button></div></fieldset></form>}
 </section>;
}
