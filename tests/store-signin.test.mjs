import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fixture} from './scheduler-fixture.mjs';
import {readLoginPreferences,saveLoginPreferences,preferenceKey} from '../src/loginPreferences.ts';
test('Remember Me stores only location and username and can be cleared',()=>{
 const map=new Map();const storage={getItem:k=>map.get(k)||null,setItem:(k,v)=>map.set(k,v),removeItem:k=>map.delete(k)};
 assert.equal(readLoginPreferences(storage),null);
 saveLoginPreferences(storage,true,{state:'Illinois',store:'downers-grove-il',username:' Alex.L ',password:'DO NOT STORE',token:'DO NOT STORE'});
 assert.deepEqual(readLoginPreferences(storage),{state:'Illinois',store:'downers-grove-il',username:'Alex.L'});
 assert.ok(!storage.getItem(preferenceKey).includes('DO NOT STORE'));
 saveLoginPreferences(storage,false,{state:'',store:'',username:''});assert.equal(readLoginPreferences(storage),null);
 storage.setItem(preferenceKey,'not JSON');assert.equal(readLoginPreferences(storage),null);
});
test('public store directory exposes only public locations and Downers Grove is the only accepted store',async()=>{
 const f=await fixture();try{
 await f.db.exec(await readFile(new URL('../supabase/migrations/033_store_signin.sql',import.meta.url),'utf8'));
 await f.db.exec('set role anon');const rows=(await f.db.query('select login_locations() r')).rows[0].r;
 assert.equal(rows.length,157);assert.deepEqual(rows.filter(s=>s.online).map(s=>s.code),['downers-grove-il']);assert.equal(rows.find(s=>s.code==='downers-grove-il').state,'Illinois');
 await assert.rejects(f.db.query("select confirm_login_store('downers-grove-il')"),/permission/);await assert.rejects(f.db.query('select * from private.login_stores'),/permission/);await f.db.exec('reset role');
 await f.as(4,"select confirm_login_store('downers-grove-il')");await assert.rejects(f.as(4,"select confirm_login_store('naperville-il')"),/not online/);await assert.rejects(f.as(6,"select confirm_login_store('downers-grove-il')"),/active access/);
 }finally{await f.db.close()}
});
