import {createClient} from 'npm:@supabase/supabase-js@2';
import {calendarText} from './ical.ts';
Deno.serve(async req=>{
 const headers={'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'};
 if(req.method!=='GET'&&req.method!=='HEAD')return new Response('Method not allowed',{status:405,headers});
 const token=new URL(req.url).searchParams.get('token');if(!token||!/^[0-9a-f]{64}$/.test(token))return new Response('Calendar unavailable',{status:404,headers});
 const client=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data,error}=await client.rpc('calendar_feed_data',{p_token:token});
 // Never log the request URL or subscription token.
 if(error)return new Response('Calendar temporarily unavailable',{status:503,headers:{...headers,'Retry-After':'60'}});
 if(!data)return new Response('Calendar unavailable',{status:404,headers});
 try{return new Response(req.method==='HEAD'?null:calendarText(data.events),{headers:{...headers,'Content-Type':'text/calendar; charset=utf-8','Content-Disposition':'inline; filename="shift.ics"'}})}catch{return new Response('Calendar temporarily unavailable',{status:503,headers})}
});
