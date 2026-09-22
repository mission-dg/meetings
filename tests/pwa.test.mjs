import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source=readFileSync(new URL('../public/sw.js',import.meta.url),'utf8');
function worker(fetch){let handler;vm.runInNewContext(source,{self:{location:{origin:'https://example.test'},addEventListener:(_,fn)=>handler=fn},URL,Response,fetch});return handler}
test('phone worker leaves Supabase data, private downloads and all writes untouched',()=>{
 const handler=worker(()=>{throw Error('Must not fetch private data')});
 for(const request of [
  {url:'https://db.supabase.co/rest/v1/staff',method:'GET',mode:'cors'},
  {url:'https://db.supabase.co/storage/v1/object/sign/private',method:'GET',mode:'navigate'},
  {url:'https://example.test/shift/',method:'POST',mode:'navigate'},
 ])handler({request,respondWith(){assert.fail('Private request intercepted')}});
});
test('offline launch returns a generic no-store reconnect page',async()=>{
 const handler=worker(async()=>{throw Error('Offline')});let response;
 handler({request:{url:'https://example.test/shift/',method:'GET',mode:'navigate'},respondWith(p){response=p}});
 const r=await response;assert.equal(r.status,503);assert.equal(r.headers.get('cache-control'),'no-store');assert.match(await r.text(),/Reconnect/);
});
test('online navigation returns the fresh server response',async()=>{
 const expected=new Response('Current release');let response;
 worker(async()=>expected)({request:{url:'https://example.test/shift/',method:'GET',mode:'navigate'},respondWith(p){response=p}});
 assert.equal(await response,expected);
});
