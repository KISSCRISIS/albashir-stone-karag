// Vercel publishes only this allowlisted runtime tree, never repository sources.
const fs=require('node:fs'),path=require('node:path');
const crypto=require('node:crypto');
const root=path.resolve(__dirname,'..'),out=path.join(root,'public-runtime');
if(out!==path.resolve(root,'public-runtime')||!out.startsWith(root+path.sep))throw Error('Invalid generated output path');
fs.rmSync(out,{recursive:true,force:true});
fs.mkdirSync(out,{recursive:true});
for(const e of fs.readdirSync(root,{withFileTypes:true})){
 if(e.isFile()&&(/\.(html|js|css|png|jpe?g|svg|webp|ico|woff2?)$/i.test(e.name)||['manifest.json','robots.txt'].includes(e.name))&&e.name!=='qr_load_test_100.js')
 fs.copyFileSync(path.join(root,e.name),path.join(out,e.name));
}
fs.cpSync(path.join(root,'assets'),path.join(out,'assets'),{recursive:true});
const hash=crypto.createHash('sha256');
for(const name of fs.readdirSync(out).sort())if(/\.(html|js|css|json)$/.test(name)){hash.update(name);hash.update(fs.readFileSync(path.join(out,name)));}
const sourceHash=hash.digest('hex');
const commit=String(process.env.VERCEL_GIT_COMMIT_SHA||'');
fs.writeFileSync(path.join(out,'app-version.json'),JSON.stringify({version:/^[a-f0-9]{40}$/.test(commit)?commit.slice(0,12):sourceHash.slice(0,12),sourceHash})+'\n');
console.log('Built public-runtime: application pages/assets only.');
