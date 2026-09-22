export type LoginPreferences={state:string;store:string;username:string};
export const preferenceKey='stars:login-preferences';
export function readLoginPreferences(storage:Pick<Storage,'getItem'>):LoginPreferences|null{
 try{const v=JSON.parse(storage.getItem(preferenceKey)||'null');return v&&typeof v.state==='string'&&typeof v.store==='string'&&typeof v.username==='string'?{state:v.state,store:v.store,username:v.username}:null}catch{return null}
}
export function saveLoginPreferences(storage:Pick<Storage,'setItem'|'removeItem'>,remember:boolean,value:LoginPreferences){
 try{if(remember)storage.setItem(preferenceKey,JSON.stringify({state:value.state,store:value.store,username:value.username.trim()}));else storage.removeItem(preferenceKey)}catch{/* Sign-in remains usable when browser storage is blocked. */}
}
