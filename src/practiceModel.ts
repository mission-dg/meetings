export type PracticeRole='employee'|'manager'|'it';
export type PracticeShift={id:string;person:string;day:number;start:number;end:number;job:string};
export type PracticeState={role:PracticeRole;draft:boolean;published:boolean;shifts:PracticeShift[];requests:{id:string;kind:string;status:string}[];people:{id:string;name:string;role:string}[];reviewed:boolean;reason:string;completed:boolean};
export function practiceStart(role:PracticeRole):PracticeState{return {role,draft:false,published:false,shifts:[],requests:[],people:[{id:'alex',name:'Alex Example',role:'Employee'},{id:'morgan',name:'Morgan Example',role:'sSHL'}],reviewed:false,reason:'',completed:false}}
export type PracticeAction={type:'draft'}|{type:'shift';shift:PracticeShift}|{type:'remove';id:string}|{type:'review';reason:string}|{type:'publish'}|{type:'request';kind:'Time off'|'Offer shift'}|{type:'accept';id:string}|{type:'approve';id:string}|{type:'person';name:string}|{type:'account';id:string;role:string};
export function practiceIssues(s:PracticeState){const issues:string[]=[];for(const a of s.shifts){if(a.end<=a.start||a.day<0||a.day>6||a.start<0||a.end>24)issues.push('Choose a valid day and time.');if(s.shifts.some(b=>a.id!==b.id&&a.person===b.person&&a.day===b.day&&a.start<b.end&&a.end>b.start))issues.push('Alex has overlapping shifts. Edit or remove one.')}return [...new Set(issues)]}
export function practiceHours(s:PracticeState){return s.shifts.filter(x=>x.person==='alex').reduce((n,x)=>n+x.end-x.start,0)}
export function practiceReduce(s:PracticeState,a:PracticeAction):PracticeState{
 const manager=['manager','it'].includes(s.role);
 if(['draft','shift','remove','review','publish'].includes(a.type)&&!manager)throw Error('This scenario requires Manager practice.');
 switch(a.type){
 case 'draft':return {...s,draft:true,shifts:[0,1,2,3].map(day=>({id:'seed'+day,person:'alex',day,start:9,end:17,job:'GSR'})),reviewed:false,published:false};
 case 'shift':if(!s.draft||s.published)throw Error('Create an editable draft first.');return {...s,shifts:[...s.shifts.filter(x=>x.id!==a.shift.id),a.shift],reviewed:false};
 case 'remove':if(!s.draft||s.published)throw Error('No editable draft.');return {...s,shifts:s.shifts.filter(x=>x.id!==a.id),reviewed:false};
 case 'review':if(!s.draft||practiceIssues(s).length)throw Error('Resolve draft issues first.');if(a.reason.trim().length<3)throw Error('Explain the hours warning and incomplete coverage setup.');return {...s,reviewed:true,reason:a.reason};
 case 'publish':if(!s.draft||!s.reviewed||practiceIssues(s).length)throw Error('Review the current draft before publishing.');return {...s,published:true,draft:false,completed:true};
 case 'request':if(s.role!=='employee')throw Error('Use Employee practice.');return {...s,requests:[...s.requests,{id:'request'+s.requests.length,kind:a.kind,status:a.kind==='Offer shift'?'Waiting on coworker':'Waiting on manager'}]};
 case 'accept':if(s.role!=='employee')throw Error('Use Employee practice.');return {...s,requests:s.requests.map(r=>r.id===a.id&&r.status==='Waiting on coworker'?{...r,status:'Waiting on manager'}:r)};
 case 'approve':if(s.role!=='employee')throw Error('Use Employee practice.');const requests=s.requests.map(r=>r.id===a.id&&r.status==='Waiting on manager'?{...r,status:'Approved'}:r);return {...s,requests,completed:['Time off','Offer shift'].every(k=>requests.some(r=>r.kind===k&&r.status==='Approved'))};
 case 'person':if(s.role!=='it'||!a.name.trim())throw Error('Enter a fictional name in IT practice.');return {...s,people:[...s.people,{id:'person'+s.people.length,name:a.name.trim(),role:'No account'}]};
 case 'account':if(s.role!=='it'||!['Employee','hSHL','sSHL'].includes(a.role))throw Error('Choose an example account type.');if(!s.people.some(p=>p.id===a.id&&p.role==='No account'))throw Error('Add a fictional teammate first.');return {...s,people:s.people.map(p=>p.id===a.id?{...p,role:a.role}:p),completed:true};
 }
}
