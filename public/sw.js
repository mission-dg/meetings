// Deliberately no Cache Storage or offline records. Supabase requests are untouched.
// New workers activate after existing windows close, never interrupting unsaved work.
self.addEventListener('fetch',event=>{
 const url=new URL(event.request.url);
 if(event.request.method!=='GET'||event.request.mode!=='navigate'||url.origin!==self.location.origin)return;
 event.respondWith(fetch(event.request).catch(()=>new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>STARS Scheduling — Offline</title><style>body{font:18px system-ui;background:#f6f3ec;color:#171717;padding:32px;max-width:560px;margin:10vh auto}button{font:inherit;padding:12px 20px}</style><h1>STARS Scheduling</h1><h2>You’re offline</h2><p>Reconnect to view your current schedule. Employee records are not stored in this offline page.</p><button onclick="location.reload()">Try again</button></html>`,{status:503,headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'}})));
});
