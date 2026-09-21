import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.57.4';
// Admin secrets live only in this server function. Never copy them into VITE variables.
const site=Deno.env.get('APP_URL')||'https://mission-dg.github.io/meetings/';
const allowedOrigin=new URL(site).origin;
Deno.serve(async(req:Request)=>{
 const cors={'Access-Control-Allow-Origin':allowedOrigin,'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};
 const response=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}});
 if(req.headers.get('origin')&&req.headers.get('origin')!==allowedOrigin)return response({error:'This website is not allowed.'},403);
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return response({error:'POST required'},405);
 try{
  const url=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_ANON_KEY')!;
  const authorization=req.headers.get('Authorization')||'';
  const caller=createClient(url,key,{global:{headers:{Authorization:authorization}},auth:{persistSession:false}});
  const {data:{user},error:authError}=await caller.auth.getUser(authorization.replace(/^Bearer\s+/i,''));
  if(authError||!user)return response({error:'Sign in again.'},401);
  const {data:profile}=await caller.from('manager_profiles').select('active,is_admin').eq('id',user.id).single();
  if(!profile?.active)return response({error:'Active manager access required.'},403);
  const body=await req.json();
  if(!profile.is_admin&&body.action!=='invite_employee')return response({error:'IT Admin access required.'},403);
  const admin=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
  if(body.action==='invite_employee'){
   const email=String(body.email||'').trim().toLowerCase(),staff=String(body.staff_id||''),submission=String(body.submission||'');
   const {data:reservation,error:reservedError}=await caller.rpc('reserve_employee_invitation',{p_staff:staff,p_email:email,p_submission:submission});
   if(reservedError)return response({error:reservedError.message},400);
   if(!reservation.fresh)return reservation.status==='Linked'?response({message:'This invitation was already sent and the employee account is linked.'}):response({error:'This invitation is already in progress or needs IT review. No additional email was sent.'},409);
   try{
    const {data,error}=await admin.auth.admin.inviteUserByEmail(email,{redirectTo:site});
    if(error){await admin.rpc('finish_employee_invitation',{p_submission:submission,p_user:null,p_error:error.message});return response({error:'Invitation could not be completed: '+error.message},400)}
    const linked=await admin.rpc('finish_employee_invitation',{p_submission:submission,p_user:data.user.id});
    if(linked.error)return response({error:'The invitation was sent, but account linking needs IT review. Workspace access remains unavailable. '+linked.error.message},409);
    return response({message:'Invitation sent. Employee access is linked to the existing staff record.'});
   }catch{return response({error:'Invitation delivery is uncertain. IT must check this reservation before another invitation is sent.'},503)}
  }
  if(!profile.is_admin)return response({error:'IT Admin access required.'},403);
  if(body.action==='invite'){
   const name=String(body.name||'').trim(),email=String(body.email||'').trim().toLowerCase();
   if(!name||name.length>120||email.length>254||!/^\S+@\S+\.\S+$/.test(email)||typeof body.is_admin!=='boolean')return response({error:'Enter a name and valid email address.'},400);
   const {data,error}=await admin.auth.admin.inviteUserByEmail(email,{redirectTo:site});
   if(error)return response({error:error.message},400);
   const result=await caller.rpc('admin_register_manager',{p_id:data.user.id,p_name:name,p_admin:body.is_admin});
   if(result.error)return response({error:'Invitation sent, but workspace approval failed. An administrator must repair this profile in Supabase before access is available. '+result.error.message},400);
   return response({message:'Invitation sent. This account is approved for access.'});
  }
  if(body.action==='send_link'){
   const {data:target}=await caller.from('manager_profiles').select('id,active').eq('id',body.id).single();
   if(!target?.active)return response({error:'Activate this manager before sending a sign-in link.'},400);
   const {data,error}=await admin.auth.admin.getUserById(target.id);
   if(error||!data.user.email)return response({error:'Account email could not be found.'},400);
   const sent=await caller.auth.signInWithOtp({email:data.user.email,options:{shouldCreateUser:false,emailRedirectTo:site}});
   if(sent.error)return response({error:sent.error.message},400);
   return response({message:'A fresh sign-in link was sent.'});
  }
  return response({error:'Unknown account action.'},400);
 }catch{return response({error:'Account service could not complete the request. Check the function and email configuration.'},500)}
});
