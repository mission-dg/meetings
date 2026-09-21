import {useEffect,useRef} from 'react';
function snapshot(form:HTMLFormElement){return JSON.stringify(Array.from(form.querySelectorAll<HTMLInputElement|HTMLSelectElement|HTMLTextAreaElement>('input,select,textarea')).map(f=>[f.name,f.type==='checkbox'||f.type==='radio'?(f as HTMLInputElement).checked:f.value]))}
export function useUnsavedChanges(){
 const forms=useRef(new Map<HTMLFormElement,string>());
 const dirty=()=>Array.from(forms.current).some(([f,initial])=>f.isConnected&&snapshot(f)!==initial);
 useEffect(()=>{
  const register=()=>{for(const f of forms.current.keys())if(!f.isConnected)forms.current.delete(f);document.querySelectorAll('form').forEach(f=>{if(!forms.current.has(f))forms.current.set(f,snapshot(f))})};register();
  const observer=new MutationObserver(register);observer.observe(document.body,{childList:true,subtree:true});
  const reset=(e:Event)=>{const f=e.target;if(f instanceof HTMLFormElement)setTimeout(()=>forms.current.set(f,snapshot(f)),0)};
  const before=(e:BeforeUnloadEvent)=>{if(dirty()){e.preventDefault();e.returnValue=''}};
  document.addEventListener('reset',reset,true);window.addEventListener('beforeunload',before);
  return()=>{observer.disconnect();document.removeEventListener('reset',reset,true);window.removeEventListener('beforeunload',before)};
 },[]);
 return ()=>!dirty()||confirm('Discard unsaved changes before leaving this screen?');
}
