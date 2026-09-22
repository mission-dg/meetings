import {readLoginPreferences,saveLoginPreferences} from './loginPreferences';
import {useEffect,useState,type FormEvent} from 'react';
import {supabase} from './client';
import {loginIdentity} from './username';

export function LoginForm(){
 const [saved]=useState(()=>{try{return readLoginPreferences(localStorage)}catch{return null}});
 const [state,setState]=useState(saved?.state||'Illinois'),[store,setStore]=useState(saved?.store||'downers-grove-il'),[remember,setRemember]=useState(!!saved);
 const [locations,setLocations]=useState<{code:string;state:string;name:string;online:boolean}[]>([]),[locationError,setLocationError]=useState('');
 const [mode,setMode]=useState<'password'|'reset'>('password');
 useEffect(()=>{let current=true;void supabase?.rpc('login_locations').then(r=>{if(!current)return;if(r.error)setLocationError('Store selection is unavailable. Please refresh or contact IT.');else setLocations(r.data)});return()=>{current=false}},[]);
 const selected=locations.find(l=>l.code===store&&l.state===state);
 useEffect(()=>{if(!remember){try{saveLoginPreferences(localStorage,false,{state,store,username:''})}catch{}}},[remember]);
 const [email,setEmail]=useState(saved?.username||''),[password,setPassword]=useState(''),[busy,setBusy]=useState(false),[error,setError]=useState(''),[message,setMessage]=useState('');
 async function submit(e:FormEvent){
  e.preventDefault();if(!supabase||busy)return;setBusy(true);setError('');setMessage('');
  try{
   if(!selected?.online)throw Error('Choose an online store. Only Downers Grove, Illinois is online.');
   const redirectTo=location.origin+import.meta.env.BASE_URL;
   const result=mode==='password'?await supabase.auth.signInWithPassword({email:loginIdentity(email),password}):await supabase.auth.resetPasswordForEmail(email.trim(),{redirectTo});
   if(result.error)throw result.error;
   if(mode==='password'){
    const check=await supabase.rpc('confirm_login_store',{p_store:store});
    if(check.error){await supabase.auth.signOut({scope:'local'});throw check.error}
    try{saveLoginPreferences(localStorage,remember,{state,store,username:email})}catch{}
   }
   setPassword('');
   if(mode!=='password')setMessage('If this email has an eligible account, a link is on its way. Check your inbox.');
  }catch(e){const err=e as {message?:string;status?:number};setError(err.status===429?'Too many attempts. Please wait before trying again. Email links and resets share the email sending limit.':err.message||'Could not sign in. Please try again.')}finally{setBusy(false)}
 }
 function change(next:typeof mode){setMode(next);setPassword('');setError('');setMessage('')}
 return <><form onSubmit={submit}><div className="form-grid"><label>State<select value={state} disabled={busy||!locations.length} onChange={e=>{setState(e.target.value);setStore('')}}>{[...new Set(locations.map(l=>l.state))].map(s=><option key={s}>{s}</option>)}</select></label><label>Store<select required value={store} disabled={busy||!locations.length} onChange={e=>setStore(e.target.value)}><option value="">Choose a store</option>{locations.filter(l=>l.state===state).map(l=><option key={l.code} value={l.code} disabled={!l.online}>{l.name}{l.online?'':' — Not online yet'}</option>)}</select></label></div>{locationError&&<p role="alert" className="error">{locationError}</p>}<p className="muted">Only Downers Grove, Illinois is online.</p><label>{mode==='password'?'Username or email address':'Email address'}<input type={mode==='password'?'text':'email'} value={email} onChange={e=>setEmail(e.target.value)} required autoComplete="username" disabled={busy}/></label>{mode==='password'&&<label>Password<input type="password" value={password} onChange={e=>setPassword(e.target.value)} required autoComplete="current-password" disabled={busy}/></label>}<label className="check"><input type="checkbox" checked={remember} disabled={busy} onChange={e=>setRemember(e.target.checked)}/>Remember Me</label><small>Remember my state, store, and username on this device. My password is not saved.</small><button className="primary full" disabled={busy||!selected?.online}>{busy?'Please wait…':mode==='password'?'Sign in':'Send password reset link'}</button></form>{message&&<p role="status" className="success">{message}</p>}{error&&<p role="alert" className="error">{error}</p>}<div className="actions auth-options">{mode!=='password'&&<button disabled={busy} onClick={()=>change('password')}>Use password</button>}{mode!=='reset'&&<button disabled={busy} onClick={()=>change('reset')}>Forgot password?</button>}</div><p className="muted">Use the username and temporary password provided by IT or the GM for your first sign-in. Email recovery only works for accounts with a real email address. Password sign-ins do not send email.</p></>;
}

export function PasswordForm({email,onSaved,onClose,required=false,ready=true}:{email:string;onSaved:()=>void;onClose:()=>void;required?:boolean;ready?:boolean}){
 const [password,setPassword]=useState(''),[confirmation,setConfirmation]=useState(''),[busy,setBusy]=useState(false),[error,setError]=useState('');
 async function submit(e:FormEvent){
  e.preventDefault();if(!supabase||busy||!ready)return;
  if(password.length<12){setError('Use at least 12 characters.');return}
  if(password!==confirmation){setError('The passwords do not match.');return}
  setBusy(true);setError('');
  try{const {error}=await supabase.auth.updateUser({password});if(error)throw error;if(required){const activation=await supabase.rpc('activate_username_account');if(activation.error)throw activation.error}setPassword('');setConfirmation('');onSaved()}catch(e){setError((e as Error).message||'Could not save your password.')}finally{setBusy(false)}
 }
 return <div className="password-page"><section className="panel password-panel"><h1>Set your password</h1><p>Account: {email}</p><p className="muted">Choose your own password with at least 12 characters. You will use it with your username or email for future sign-ins.</p>{required&&<p className="notice">{ready?'Change the temporary password before you can access the workspace.':'Sign out and sign in with your latest login details. If the temporary password expired or setup is incomplete, ask IT or the GM for help.'}</p>}<form onSubmit={submit}><label>New password<input type="password" required minLength={12} autoComplete="new-password" value={password} onChange={e=>setPassword(e.target.value)} disabled={busy||!ready}/></label><label>Confirm password<input type="password" required minLength={12} autoComplete="new-password" value={confirmation} onChange={e=>setConfirmation(e.target.value)} disabled={busy}/></label>{error&&<p className="error" role="alert">{error}</p>}<div className="actions"><button type="button" disabled={busy} onClick={()=>{if((!password&&!confirmation)||confirm('Discard the password you entered?'))onClose()}}>{required?'Sign out':'Back to workspace'}</button><button className="primary" disabled={busy||!ready}>{busy?'Saving…':'Save password'}</button></div></form></section></div>;
}
