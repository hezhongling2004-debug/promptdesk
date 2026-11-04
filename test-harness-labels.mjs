import vm from 'node:vm';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const rows = [
  {name:'promptdesk-test',description:'用于「苏格拉底式提问」（提问）。仅当用户请求时使用。'},
  {name:'office-pptx',description:'PowerPoint'},
];
let loader;
const context=vm.createContext({window:{__ModuleLoader__:{load(v){loader=v;}}},setInterval:()=>1,clearInterval:()=>{}});
const code=fs.readFileSync(new URL('./Assets/harness-labels.cjs',import.meta.url),'utf8').replace('__PROMPTDESK_LABELS__','{}');
vm.runInContext(code,context);
const source={trigger:'/',name:'skill',async candidates(){return rows;}};
const original=source.candidates; let dispose;
loader.factory().apply({inputTriggers:{live:{sources:[source]}},effect(f){dispose=f();}});
const all=await source.candidates({}, {query:'',signal:{aborted:false}});
assert.equal(all[0].label,'苏格拉底式提问');
assert.equal(all[0].name,'promptdesk-test');
assert.equal(all[1].label,undefined);
const filtered=await source.candidates({}, {query:'苏格拉底',signal:{aborted:false}});
assert.equal(filtered.length,1);
dispose(); assert.equal(source.candidates,original);
console.log('PASS: Harness Chinese labels, Chinese search, stable invocation, unrelated skills, cleanup');
