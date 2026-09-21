import { createClient } from '@supabase/supabase-js';
const url=import.meta.env.VITE_SUPABASE_URL, key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
function validKey(k:string){if(k.startsWith('sb_publishable_'))return true;try{return JSON.parse(atob(k.split('.')[1])).role==='anon'}catch{return false}}
export const configured=!!url&&/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(url)&&!!key&&validKey(key);
export const supabase=configured?createClient(url,key,{auth:{flowType:'pkce',persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;
