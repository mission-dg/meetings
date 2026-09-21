import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
const raw=(await readFile(new URL('../supabase/functions/manage-accounts/index.ts',import.meta.url),'utf8')).replace(/^import .*\n/,'');
const compiled=ts.transpileModule(raw,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
function handler({authenticated=true,isAdmin=true,approvalError=null}={}){
 let handle;const calls=[];
 const caller={auth:{getUser:async()=>({data:{user:authenticated?{id:'admin'}:null},error:null}),signInWithOtp:async args=>{calls.push(['link',args]);return {error:null}}},from:()=>({select:()=>({eq:()=>({single:async()=>({data:{id:'target',active:true,is_admin:isAdmin}})})})}),rpc:async(name,args)=>{calls.push([name,args]);return {error:approvalError}}};
 const admin={auth:{admin:{inviteUserByEmail:async(email,args)=>{calls.push(['invite',email,args]);return {data:{user:{id:'new'}},error:null}},getUserById:async()=>({data:{user:{email:'manager@example.com'}},error:null})}}};
 vm.runInNewContext(compiled,{Request,Response,URL,createClient:(_url,key)=>{calls.push(['client',key]);return key==='service'?admin:caller},Deno:{env:{get:name=>({APP_URL:'https://mission-dg.github.io/meetings/',SUPABASE_URL:'https://test.supabase.co',SUPABASE_ANON_KEY:'anon',SUPABASE_SERVICE_ROLE_KEY:'service'})[name]},serve:fn=>{handle=fn}}});
 return {calls,request:(body,origin='https://mission-dg.github.io')=>handle(new Request('https://test.supabase.co/functions/v1/manage-accounts',{method:'POST',headers:{Authorization:'Bearer token',Origin:origin,'Content-Type':'application/json'},body:JSON.stringify(body)}))};
}
test('account endpoint rejects unauthenticated/nonadmin callers before using service credentials',async()=>{
 for(const setup of [{authenticated:false},{isAdmin:false}]){const h=handler(setup),r=await h.request({action:'invite'});assert.ok([401,403].includes(r.status));assert.ok(!h.calls.some(c=>c[1]==='service'))}
 const h=handler();assert.equal((await h.request({action:'invite'},'https://unrelated.example')).status,403);assert.equal(h.calls.length,0);
});
test('invitation approval uses caller credentials; partial failure is explicit; sign-in links use approved account email',async()=>{
 const h=handler();assert.equal((await h.request({action:'invite',name:' Taylor ',email:'Taylor@example.com',is_admin:false})).status,200);
 assert.ok(h.calls.some(c=>c[0]==='admin_register_manager'&&c[1].p_id==='new'&&c[1].p_admin===false));
 const failed=handler({approvalError:{message:'Please retry'}});const result=await failed.request({action:'invite',name:'Taylor',email:'t@example.com',is_admin:false});assert.equal(result.status,400);assert.match((await result.json()).error,/Invitation sent, but workspace approval failed/);
 const link=handler();assert.equal((await link.request({action:'send_link',id:'target',email:'attacker@example.com'})).status,200);assert.ok(link.calls.some(c=>c[0]==='link'&&c[1].email==='manager@example.com'&&c[1].options.shouldCreateUser===false));
});
