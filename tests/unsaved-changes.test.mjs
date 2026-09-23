import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

test('successful form save clears only that form; failures and later edits remain protected',()=>{
 const listeners=new Map();let effect;let prompts=0;const forms=[];
 class Form {isConnected=true;fields=[{name:'title',type:'text',value:''}];querySelectorAll(){return this.fields}dispatchEvent(e){Object.defineProperty(e,'target',{value:this});listeners.get(e.type)?.(e);return true}}
 const context={exports:{},require:()=>({useRef:v=>({current:v}),useEffect:f=>{effect=f}}),HTMLFormElement:Form,Event,MutationObserver:class{observe(){}disconnect(){}},document:{querySelectorAll:()=>forms,body:{},addEventListener:(n,f)=>listeners.set(n,f),removeEventListener:n=>listeners.delete(n)},window:{addEventListener(){},removeEventListener(){}},confirm:()=>{prompts++;return false},setTimeout};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(new URL('../src/useUnsavedChanges.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,context);
 const meeting=new Form(),other=new Form();forms.push(meeting,other);
 const canLeave=context.exports.useUnsavedChanges();const cleanup=effect();
 assert.equal(canLeave(),true);
 meeting.fields[0].value='Team meeting';
 assert.equal(canLeave(),false,'not saved or failed save must stay dirty');
 context.exports.markFormSaved(meeting);
 assert.equal(canLeave(),true,'successful save permits immediate navigation before unmount');
 other.fields[0].value='Unrelated edit';context.exports.markFormSaved(meeting);
 assert.equal(canLeave(),false,'saving a meeting cannot discard another form');
 context.exports.markFormSaved(other);meeting.fields[0].value='New unsaved change';
 assert.equal(canLeave(),false,'editing again reinstates warning');
 assert.equal(prompts,3);cleanup();
});
