const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const root=path.join(__dirname,'..');execFileSync(process.execPath,[path.join(root,'scripts/build-public-runtime.cjs')]);
const out=path.join(root,'public-runtime');
for(const name of ['portal.html','verify.html','guard.html','employee-photo.js','manifest.json','assets/images/portal-reference.png'])assert(fs.existsSync(path.join(out,name)),name);
for(const name of ['supabase','tests','docs','scripts','schema_consolidated_fresh_install.sql','PROJECT_RULES.md','package.json','.git','.env.local','qr_load_test_100.js'])assert(!fs.existsSync(path.join(out,name)),name);
const cfg=JSON.parse(fs.readFileSync(path.join(root,'vercel.json'),'utf8'));assert.equal(cfg.outputDirectory,'public-runtime');assert.equal(cfg.buildCommand,'node scripts/build-public-runtime.cjs');
console.log('PASS public build contains runtime/guard direct link only; SQL, documentation, tests and credentials excluded');
