const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const html=fs.readFileSync(path.join(__dirname,'../register.html'),'utf8');
const source=html.slice(html.indexOf('  const MAX_PHOTO_BYTES'),html.indexOf('  async function uploadEmployeePhoto'));
(async()=>{
  const browser=await chromium.launch();
  try{
    const page=await browser.newPage();
    await page.addScriptTag({content:source});
    const result=await page.evaluate(async()=>{
      const canvas=document.createElement('canvas');canvas.width=2400;canvas.height=2400;
      const context=canvas.getContext('2d'),pixels=context.createImageData(2400,2400);
      let seed=123;for(let i=0;i<pixels.data.length;i+=4){seed=(Math.imul(seed,1664525)+1013904223)>>>0;pixels.data[i]=seed&255;pixels.data[i+1]=(seed>>>8)&255;pixels.data[i+2]=(seed>>>16)&255;pixels.data[i+3]=255;}
      context.putImageData(pixels,0,0);
      const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));
      const input=new File([blob],'large.png',{type:'image/png'});
      const prepared=await prepareEmployeePhoto(input);
      const bitmap=await createImageBitmap(prepared.file);
      const dimensions=[bitmap.width,bitmap.height];bitmap.close();
      const small=new File([prepared.file],'small.jpg',{type:''});
      const kept=await prepareEmployeePhoto(small);
      let mismatch=false,unsupported=false,invalidSmall=false;
      try{await prepareEmployeePhoto(new File([blob],'bad.png',{type:'image/jpeg'}));}catch{mismatch=true;}
      try{await prepareEmployeePhoto(new File(['invalid'],'photo.heic',{type:'image/heic'}));}catch(e){unsupported=e.message.includes('HEIC/HEIF');}
      try{await prepareEmployeePhoto(new File(['invalid'],'photo.jpg',{type:'image/jpeg'}));}catch{invalidSmall=true;}
      const decode=createImageBitmap;
      window.createImageBitmap=async()=>{throw Error('ImageBitmap format unsupported');};
      let fallback;
      try{fallback=await prepareEmployeePhoto(small);}finally{window.createImageBitmap=decode;}
      return {inputBytes:input.size,outputBytes:prepared.file.size,type:prepared.file.type,extension:prepared.extension,dimensions,emptyMimeAccepted:kept.mimeType==='image/jpeg',mismatch,unsupported,invalidSmall,fallback:fallback.mimeType==='image/jpeg'};
    });
    assert(result.inputBytes>2097152);assert(result.outputBytes<=2097152);assert.equal(result.type,'image/jpeg');assert.equal(result.extension,'jpg');assert(Math.max(...result.dimensions)<=1600);
    assert(result.emptyMimeAccepted&&result.mismatch&&result.unsupported&&result.invalidSmall&&result.fallback);
    console.log('PASS real browser photo decoding, compression, output size/dimensions, empty MIME, mismatched format and unsupported HEIC handling');
  }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
