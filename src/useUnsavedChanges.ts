import {useEffect,useRef} from 'react';
function snapshot(form:HTMLFormElement){return JSON.stringify(Array.from(form.querySelectorAll<HTMLInputElement|HTMLSelectElement|HTMLTextAreaElement>('input,select,textarea')).map(f=>[f.name,f.type==='checkbox'||f.type==='radio'?(f as HTMLInputElement).checked:f.value]))}
// Saving one form must not clear unsaved edits in any other form.
export function markFormSaved(form:HTMLFormElement){form.dispatchEvent(new Event('stars:form-saved',{bubbles:true}))}
export function useUnsavedChanges(){
 const forms=useRef(new Map<HTMLFormElement,string>());
 const dirty=()=>Array.from(forms.current).some(([f,initial])=>f.isConnected&&snapshot(f)!==initial);
 useEffect(()=>{
  const announce=()=>window.dispatchEvent(new CustomEvent('stars:dirty',{detail:dirty()}));
  const register=()=>{for(const f of forms.current.keys())if(!f.isConnected)forms.current.delete(f);document.querySelectorAll('form').forEach(f=>{if(!forms.current.has(f))forms.current.set(f,snapshot(f))})};register();
  const observer=new MutationObserver(()=>{register();announce()});observer.observe(document.body,{childList:true,subtree:true});
  const reset=(e:Event)=>{const f=e.target;if(f instanceof HTMLFormElement)setTimeout(()=>{forms.current.set(f,snapshot(f));announce()},0)};
  const saved=(e:Event)=>{const f=e.target;if(f instanceof HTMLFormElement)forms.current.set(f,snapshot(f));announce()};
  const before=(e:BeforeUnloadEvent)=>{if(dirty()){e.preventDefault();e.returnValue=''}};
  document.addEventListener('input',announce,true);document.addEventListener('change',announce,true);document.addEventListener('reset',reset,true);document.addEventListener('stars:form-saved',saved,true);window.addEventListener('beforeunload',before);
  return()=>{observer.disconnect();document.removeEventListener('input',announce,true);document.removeEventListener('change',announce,true);document.removeEventListener('reset',reset,true);document.removeEventListener('stars:form-saved',saved,true);window.removeEventListener('beforeunload',before)};
 },[]);
 return ()=>!dirty()||confirm('Discard unsaved changes before leaving this screen?');
}
