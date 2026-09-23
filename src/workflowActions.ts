import {useEffect,useRef} from 'react';
import type {SchedulerData} from './scheduler';
export type CreateAction='shift'|'training'|'staffMeeting'|'oneOnOne'|'announcement'|'employee';
export type ActionContext={person?:string;job?:string;shift?:string;date?:string;week?:string};
export const createActions:{id:CreateAction;label:string;page:string;allowed:(d:SchedulerData)=>boolean}[]=[
 {id:'shift',label:'Work shift',page:'schedule',allowed:d=>d.self.is_manager},
 {id:'training',label:'Training assignment',page:'schedule',allowed:d=>d.self.is_manager},
 {id:'staffMeeting',label:'Staff meeting',page:'staffMeetings',allowed:d=>d.self.is_manager},
 {id:'oneOnOne',label:'1:1',page:'schedule',allowed:d=>d.self.is_manager},
 {id:'announcement',label:'Announcement',page:'announcements',allowed:d=>d.self.is_manager||d.self.is_ca},
 {id:'employee',label:'Employee',page:'directory',allowed:d=>d.self.is_admin}
];
export function useCreateIntent(id:CreateAction,run:(context:ActionContext)=>void,enabled=true){
 const callback=useRef(run);callback.current=run;
 useEffect(()=>{if(!enabled)return;const handle=(e:Event)=>{const detail=(e as CustomEvent<{action:CreateAction;context:ActionContext}>).detail;if(detail.action===id)callback.current(detail.context)};window.addEventListener('stars:create',handle);
 const url=new URL(location.href);if(url.searchParams.get('create')===id){const context:ActionContext={};for(const key of ['person','job','shift','date','week'] as const){const value=url.searchParams.get(key);if(value)context[key]=value}url.searchParams.delete('create');history.replaceState(null,'',url);callback.current(context)}
 return()=>window.removeEventListener('stars:create',handle)},[id,enabled]);
}
