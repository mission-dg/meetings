import type {WorkShift} from './scheduler.ts';
import {shiftDay,hours} from './scheduler.ts';
export type Rate={id:string;person_id:string;effective:string;hourly_rate:number;version:number};
export type Forecast={day:string;amount:number;version:number};
export function laborRows(shifts:WorkShift[],rates:Rate[],forecasts:Forecast[]){
 const dates=[...new Set(shifts.map(s=>shiftDay(s.start)))].sort();
 return dates.map(day=>{const items=shifts.filter(s=>shiftDay(s.start)===day);let cost=0,missing=0;for(const s of items){const rate=rates.filter(r=>r.person_id===s.person_id&&r.effective<=day).sort((a,b)=>b.effective.localeCompare(a.effective))[0];if(!rate)missing++;else cost+=(Date.parse(s.end)-Date.parse(s.start))/3600000*Number(rate.hourly_rate)}const forecast=forecasts.find(f=>f.day===day);return {day,hours:hours(items),cost:Math.round(cost*100)/100,missing,sales:forecast?Number(forecast.amount):null,percent:!missing&&forecast&&Number(forecast.amount)>0?Math.round(cost/Number(forecast.amount)*1000)/10:null}});
}
export function csvText(rows:unknown[][]){return rows.map(row=>row.map(cell=>{let s=String(cell??'');if(/^[=+@\-\t\r]/.test(s))s="'"+s;return '"'+s.replaceAll('"','""')+'"'}).join(',')).join('\r\n')}
export function downloadCsv(filename:string,rows:unknown[][]){const url=URL.createObjectURL(new Blob([csvText(rows)],{type:'text/csv;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download=filename;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)}
