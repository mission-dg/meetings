import {useEffect,useState} from 'react';

type InstallPrompt=Event&{prompt:()=>Promise<void>;userChoice:Promise<{outcome:string}>};
export function InstallApp(){
 const [prompt,setPrompt]=useState<InstallPrompt|null>(null);
 const [installed,setInstalled]=useState(()=>window.matchMedia('(display-mode: standalone)').matches||Boolean((navigator as Navigator&{standalone?:boolean}).standalone));
 const [offline,setOffline]=useState(!navigator.onLine);
 const [error,setError]=useState('');
 useEffect(()=>{
  const offer=(e:Event)=>{e.preventDefault();setPrompt(e as InstallPrompt)};
  const done=()=>{setInstalled(true);setPrompt(null)};
  const online=()=>setOffline(!navigator.onLine);
  window.addEventListener('beforeinstallprompt',offer);window.addEventListener('appinstalled',done);
  window.addEventListener('online',online);window.addEventListener('offline',online);
  return()=>{window.removeEventListener('beforeinstallprompt',offer);window.removeEventListener('appinstalled',done);window.removeEventListener('online',online);window.removeEventListener('offline',online)};
 },[]);
 async function install(){if(!prompt)return;try{await prompt.prompt();await prompt.userChoice;setPrompt(null)}catch{setError('Use your browser menu to add STARS to your home screen.');setPrompt(null)}}
 return <div className="install-app">{offline&&<p className="notice" role="status">You’re offline. Reconnect and refresh before using schedules or saving changes.</p>}{!installed&&<details><summary>Add STARS to your phone</summary><p>Open your schedule from your home screen. Internet access is required.</p>{prompt&&<button type="button" onClick={()=>void install()}>Install STARS Scheduling</button>}<p><strong>iPhone / iPad:</strong> Open this site in Safari, tap Share, then Add to Home Screen. If offered, keep Open as Web App enabled.</p><p><strong>Android:</strong> Open this site in Chrome, then choose Install app or Add to Home screen from the browser menu.</p>{error&&<p role="status">{error}</p>}</details>}</div>;
}
