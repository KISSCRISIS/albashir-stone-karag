// Vercel publishes only this allowlisted runtime tree, never repository sources.
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..'),out=path.join(root,'public-runtime');
if(out!==path.resolve(root,'public-runtime')||!out.startsWith(root+path.sep))throw Error('Invalid generated output path');
fs.rmSync(out,{recursive:true,force:true});
fs.mkdirSync(out,{recursive:true});
for(const e of fs.readdirSync(root,{withFileTypes:true})){
 if(e.isFile()&&(/\.(html|js|css|png|jpe?g|svg|webp|ico|woff2?)$/i.test(e.name)||['manifest.json','robots.txt'].includes(e.name))&&e.name!=='qr_load_test_100.js')
 fs.copyFileSync(path.join(root,e.name),path.join(out,e.name));
}
fs.cpSync(path.join(root,'assets'),path.join(out,'assets'),{recursive:true});
console.log('Built public-runtime: application pages/assets only.');
