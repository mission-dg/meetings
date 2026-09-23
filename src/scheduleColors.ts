import type {WorkShift} from './scheduler.ts';
// Stable preset identifiers shared with migration 037.
export const colorPresets=[
 ['ocean','Ocean blue','#0759b2','#edf4fd'],['forest','Forest green','#326c42','#edf6ee'],['violet','Violet','#7942c0','#f4eefb'],['rust','Rust','#aa430e','#fff1e9'],['teal','Teal','#256e70','#eaf6f5'],['rose','Rose','#ad396e','#fceef3'],['indigo','Indigo','#192d67','#f0effd'],['olive','Olive','#737d00','#f4f6e7'],['copper','Copper','#70451f','#faf2e6'],['berry','Berry','#b40098','#f9edf9'],['slate','Slate blue','#506c84','#edf3f7'],['jade','Jade','#007342','#e8f7ef'],['cranberry','Cranberry','#bb1e2e','#fceef0'],['azure','Azure','#007d95','#e9f6fc'],['plum','Plum','#754b76','#f5eff6'],['ochre','Ochre','#9a7300','#faf5df'],['pine','Pine','#326257','#edf5f1'],['clay','Clay','#956451','#f9f1ed'],['periwinkle','Periwinkle','#616caa','#f1f2fb'],['moss','Moss','#567042','#f0f6ea'],['magenta','Magenta','#984d79','#faeff6'],['denim','Denim','#3a6280','#edf4f9'],['cinnamon','Cinnamon','#8b4b35','#faeee8'],['grape','Grape','#624c88','#f2eff9']
].map(([id,name,edge,background])=>({id,name,edge,background}));
export const specialColorKeys=[['type:opening_office','Opening office'],['type:closing_office','Closing office'],['type:training','Dedicated training'],['type:staff_meeting','Staff meeting'],['type:shl','General SHL duty']] as const;
export type ScheduleColors={version:number;assignments:Record<string,string>;defaults:Record<string,string>;palette?:string;overrides?:Record<string,string>};
type Job={id:string;name:string;active:boolean};
export const specialDefaults:Record<string,string>={'type:opening_office':'slate','type:closing_office':'violet','type:training':'rose','type:staff_meeting':'rust','type:shl':'ochre'};
export const preferredJobColors:Record<string,string>={GSR:'ocean',Line:'jade',EXPO:'azure',Prep:'indigo',DRL:'olive',Catering:'berry',CA:'copper',TA:'cranberry',hSHL:'forest',sSHL:'plum',GM:'teal'};
export function defaultColors(jobs:Job[]):ScheduleColors{const defaults={...specialDefaults};const sorted=[...jobs].sort((a,b)=>a.name.localeCompare(b.name)||a.id.localeCompare(b.id));for(const j of sorted){const preferred=preferredJobColors[j.name];if(preferred&&!Object.values(defaults).includes(preferred))defaults['job:'+j.id]=preferred;}for(const j of sorted){if(defaults['job:'+j.id])continue;defaults['job:'+j.id]=(colorPresets.find(p=>!Object.values(defaults).includes(p.id))||colorPresets[Object.keys(defaults).length%colorPresets.length]).id;}return {version:0,assignments:defaults,defaults};}
export function shiftColorKey(shift:WorkShift,meetingShifts:Record<string,string>={}){if(meetingShifts[shift.id]&&shift.assignment_type==='training')return 'type:staff_meeting';if(shift.assignment_type&&shift.assignment_type!=='regular')return 'type:'+shift.assignment_type;return shift.job_id?'job:'+shift.job_id:'type:shl';}
export function colorFor(key:string,colors:ScheduleColors|undefined,jobs:Job[]){const fallback=defaultColors(jobs);const id=colors?.assignments[key]||colors?.defaults[key]||fallback.assignments[key];const p=colorPresets.find(p=>p.id===id)||colorPresets[0];return styledPreset(p,colors?.overrides?.[key]?'classic':colors?.palette||'classic');}
export function colorEntries(jobs:Job[],keys?:Set<string>){return [...jobs.filter(j=>keys?keys.has('job:'+j.id):j.active).map(j=>({key:'job:'+j.id,label:j.name})),...specialColorKeys.filter(([key])=>!keys||keys.has(key)).map(([key,label])=>({key,label}))];}
export const palettes=[{id:'classic',name:'Classic'},{id:'vivid',name:'Vivid'},{id:'soft',name:'Soft'}] as const;
export type Appearance={version:number;mode:'light'|'dark'|'system';palette:string;overrides:Record<string,string>;defaults:Record<string,string>};
export function defaultAppearance(jobs:Job[]):Appearance{return {version:0,mode:'light',palette:'classic',overrides:{},defaults:defaultColors(jobs).defaults};}
export function appearanceColors(a:Appearance):ScheduleColors{return {version:a.version,defaults:a.defaults,palette:a.palette,overrides:a.overrides,assignments:{...a.defaults,...a.overrides}};}
// Different hues are kept in the same job slots across palettes. Saturation, not
// assignment order, changes so switching palettes never makes related hues cluster.
const darkAccents=['#69b6ff','#8ed67d','#c895ff','#ffac70','#56d9dc','#ff82b0','#909aff','#d6df6c','#eac18b','#ff65de','#acb7c5','#53e5ae','#ff7d82','#50d6ff','#d7acd7','#ffde55','#91ccba','#e4b4a0','#b5c0ff','#bdd99b','#efa8d4','#9dc8e8','#efad90','#c5ade9'];
function mix(a:string,b:string,n:number){return '#'+[1,3,5].map(i=>Math.round(parseInt(a.slice(i,i+2),16)*(1-n)+parseInt(b.slice(i,i+2),16)*n).toString(16).padStart(2,'0')).join('');}
export function styledPreset(p:typeof colorPresets[number],palette:string){const accent=darkAccents[colorPresets.findIndex(x=>x.id===p.id)]||darkAccents[0];return {...p,edge:palette==='vivid'?mix(p.edge,'#000000',.12):p.edge,background:palette==='soft'?mix(p.background,'#ffffff',.55):palette==='vivid'?mix(p.background,p.edge,.10):p.background,darkEdge:palette==='soft'?mix(accent,'#ffffff',.20):accent,darkBackground:mix(p.edge,'#242424',palette==='soft'?.65:palette==='vivid'?.3:.45)};}
export function presetLuminance(hex:string){const c=[1,3,5].map(i=>parseInt(hex.slice(i,i+2),16)/255).map(n=>n<=.04045?n/12.92:((n+.055)/1.055)**2.4);return c[0]*.2126+c[1]*.7152+c[2]*.0722;}
// Picker-only ordering: never reorder the stable preset catalog or saved IDs.
export const presetGroups=[
 {label:'Reds & pinks',ids:['rose','cranberry','magenta']},
 {label:'Blues',ids:['ocean','azure','slate','periwinkle','denim','indigo']},
 {label:'Greens & teals',ids:['forest','teal','jade','pine','moss']},
 {label:'Golds & yellows',ids:['olive','ochre']},
 {label:'Oranges & browns',ids:['rust','copper','clay','cinnamon']},
 {label:'Purples',ids:['violet','berry','plum','grape']}
].map(g=>({label:g.label,presets:g.ids.map(id=>colorPresets.find(p=>p.id===id)!).sort((a,b)=>presetLuminance(b.edge)-presetLuminance(a.edge))}));
