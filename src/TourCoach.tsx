import {useEffect,useRef,useState} from 'react';
import {createPortal} from 'react-dom';
import type {TourStep} from './walkthroughs';
import type {Workspace} from './scheduler';
import './tourCoach.css';

type FocusTarget={element:HTMLElement;instruction:string;navigation:boolean};
const visible=(element:HTMLElement|null|undefined):element is HTMLElement=>!!element&&!!element.getClientRects().length&&getComputedStyle(element).visibility!=='hidden';
function findTarget(step:TourStep,page:string,workspace:Workspace):FocusTarget|null{
 const lookup=(selector:string)=>Array.from(document.querySelectorAll<HTMLElement>(selector)).find(visible);
 if(page!==step.page){
  const destination=lookup(`[data-tour-nav="${step.page}"]`);
  if(destination)return {element:destination,instruction:`Select “${destination.textContent?.trim()}”.`,navigation:true};
  if(workspace==='employee'){
   const more=lookup('[data-tour-nav="more"]');
   return more?{element:more,instruction:'Select “More” to find this page.',navigation:true}:null;
  }
  const hidden=document.querySelector<HTMLElement>(`[data-tour-nav="${step.page}"]`);
  const group=hidden?.closest('.nav-group')?.querySelector<HTMLElement>('.nav-group-toggle');
  if(visible(group))return {element:group,instruction:`Expand “${group.textContent?.replace(/[▸▾]/g,'').trim()}”.`,navigation:true};
  const menu=lookup('.management-menu');
  return menu?{element:menu,instruction:'Select “Menu” to open the navigation.',navigation:true}:null;
 }
 let target=lookup(`[data-tour="${step.target}"]`);
 if(step.target==='page-content'){
  const areas:Record<string,string>={home:'.next-shift, [data-tour="manager-actions"]',schedule:'.day-shift, .schedule-controls',requests:'.availability-summary, .request-list',more:'.more-grid',training:'.training-dashboard .filters, .training-progress-row',staffMeetings:'.staff-meeting-card, .section-title',accounts:'.profile-tabs',settings:'.profile-tabs',directory:'.filters',announcements:'.panel'};
  target=lookup(areas[page]||'[data-tour="page-content"] h1')||lookup('[data-tour="page-content"] h1')||target;
 }
 if(target?.tagName==='DETAILS')target=target.querySelector<HTMLElement>('summary')||target;
 return target?{element:target,instruction:step.clickToAdvance?'Select the highlighted control to continue.':'Look at the highlighted area.',navigation:false}:null;
}
export function TourCoach({step,page,workspace,title,index,total,onBack,onContinue,onExit}:{step:TourStep;page:string;workspace:Workspace;title:string;index:number;total:number;onBack:()=>void;onContinue:()=>void;onExit:()=>void}){
 const [target,setTarget]=useState<FocusTarget|null>(null),[box,setBox]=useState<DOMRect|null>(null);
 const card=useRef<HTMLElement>(null),continueRef=useRef(onContinue);continueRef.current=onContinue;
 useEffect(()=>{
  let highlighted:HTMLElement|undefined,frame=0;
  const update=()=>{const found=findTarget(step,page,workspace);if(highlighted!==found?.element){highlighted?.classList.remove('tour-highlight');highlighted=found?.element;highlighted?.classList.add('tour-highlight');highlighted?.scrollIntoView({block:'nearest',inline:'nearest',behavior:'instant'});}setTarget(old=>old?.element===found?.element&&old?.instruction===found?.instruction?old:found);const rect=found?.element.getBoundingClientRect();setBox(old=>rect&&old&&rect.x===old.x&&rect.y===old.y&&rect.width===old.width&&rect.height===old.height?old:rect||null);};
  const schedule=()=>{cancelAnimationFrame(frame);frame=requestAnimationFrame(update)};
  const observer=new MutationObserver(schedule);observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden','open','aria-expanded','class']});
  window.addEventListener('resize',schedule);window.addEventListener('scroll',schedule,true);update();
  const click=(event:MouseEvent)=>{if(page===step.page&&step.clickToAdvance&&highlighted?.contains(event.target as Node)){setTimeout(()=>continueRef.current(),0)}else schedule()};
  const key=(event:KeyboardEvent)=>{if(event.key==='Escape'){event.preventDefault();onExit()}};
  document.addEventListener('click',click,true);document.addEventListener('keydown',key);card.current?.focus({preventScroll:true});
  return()=>{observer.disconnect();cancelAnimationFrame(frame);highlighted?.classList.remove('tour-highlight');window.removeEventListener('resize',schedule);window.removeEventListener('scroll',schedule,true);document.removeEventListener('click',click,true);document.removeEventListener('keydown',key)};
 },[step,page,workspace]);
 const navigation=page!==step.page;
 const below=box?box.top<window.innerHeight/2:true;
 const x=box?Math.max(30,Math.min(window.innerWidth-30,box.left+Math.min(box.width/2,100))):0;
 const y=box?(below?Math.min(window.innerHeight-34,box.bottom+8):Math.max(34,box.top-8)):0;
 return createPortal(<>
 {box&&<div className={'tour-pointer '+(below?'points-up':'points-down')} style={{left:x,top:y}} aria-hidden="true">{below?'↑':'↓'}</div>}
 <aside ref={card} tabIndex={-1} className={'tour-coach '+(box&&box.top>window.innerHeight/2?'coach-top':'')} role="region" aria-label={title+' walkthrough'}>
 <button className="tour-coach-close" aria-label="Exit walkthrough" onClick={onExit}>×</button>
 <p className="muted">{title} · Step {index+1} of {total}</p><h2>{step.title}</h2>
 <p aria-live="polite">{target?.instruction||'This area is not available right now. You can skip this step or exit and return from Settings → My account.'}</p>
 {!navigation&&<p>{step.text}</p>}
 <p className="muted">Use the normal controls. The guide does not save or publish for you.</p>
 <div className="actions"><button disabled={index===0} onClick={onBack}>Back</button><button onClick={onExit}>Exit tour</button>{!target?<button onClick={onContinue}>Skip unavailable step</button>:!navigation&&!step.clickToAdvance?<button className="primary" onClick={onContinue}>{index===total-1?'Finish':'Continue'}</button>:<button onClick={()=>target.element.focus()}>Focus highlighted control</button>}</div>
 </aside>
 </>,document.body);
}
