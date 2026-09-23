let active=false;
export function setPracticeIsolation(value:boolean){active=value}
export function isPracticeIsolated(){return active}
export function practiceRequestAllowed(url:string){const path=new URL(url).pathname;return path.startsWith('/auth/v1/')||path==='/rest/v1/rpc/onboarding_save'}
export const isolatedFetch:typeof fetch=(input,init)=>{const url=typeof input==='string'?input:input instanceof URL?input.href:input.url;if(active&&!practiceRequestAllowed(url))return Promise.reject(new Error('Live data access is disabled while practice is open. Exit practice to continue.'));return fetch(input,init)};
