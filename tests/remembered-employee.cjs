const fs=require('fs'),vm=require('vm'),assert=require('assert/strict'),path=require('path');
const code=fs.readFileSync(path.join(__dirname,'../access-control.js'),'utf8');
const storage=()=>{const m=new Map();return {getItem:k=>m.get(k)??null,setItem:(k,v)=>m.set(k,String(v)),removeItem:k=>m.delete(k),clear:()=>m.clear()};};
const local=storage();function tab(){const c={window:{},document:{currentScript:{dataset:{}}},sessionStorage:storage(),localStorage:local,Date};vm.createContext(c);vm.runInContext(code,c);return c;}
const first=tab();first.window.ALBASHIRAccess.setSession('EMPLOYEE',{employeeId:'SYNTHETIC',mobileNumber:'000-SYN',rememberMe:true});
const reopened=tab();assert.equal(reopened.window.ALBASHIRAccess.readSession().employeeId,'SYNTHETIC');assert.equal(reopened.window.ALBASHIRAccess.readSession().role,'EMPLOYEE');
local.setItem('alb_remembered_employee_v1',JSON.stringify({role:'SUPER_ADMIN',employeeId:'SYNTHETIC',mobileNumber:'000-SYN'}));assert.equal(tab().window.ALBASHIRAccess.readSession().role,'EMPLOYEE');
reopened.window.ALBASHIRAccess.clearSession();assert.equal(tab().window.ALBASHIRAccess.readSession(),null);
first.window.ALBASHIRAccess.setSession('EMPLOYEE',{employeeId:'SYNTHETIC',mobileNumber:'000-SYN',rememberMe:false});assert.equal(tab().window.ALBASHIRAccess.readSession(),null);
first.window.ALBASHIRAccess.setSession('SUPER_ADMIN',{});assert.equal(tab().window.ALBASHIRAccess.readSession(),null);
console.log('PASS remembered employee across tabs; opt-out/logout clear; no remembered admin authority');

(async()=>{
const html=fs.readFileSync(path.join(__dirname,'../verify.html'),'utf8');
const source=html.slice(html.indexOf('  async function submitEmployeeVerification(){'),html.indexOf('  $("checkForm").addEventListener'));
for(const [accepted,remember] of [[true,true],[true,false],[false,true]]){
let saved=null,rendered=false;const elements={checkEmployeeId:{value:'SYN'},checkMobileNumber:{value:'000'},rememberVerifiedEmployee:{checked:remember}};
const c={verificationLock:false,activeQrToken:'CLAIM',activeQrRequestId:null,supabaseClient:{},navigator:{onLine:true},qrClaimReady:true,employeeSession:null,lastManualCheck:null,$:id=>elements[id],disableButton:()=>{},getTrustedDeviceId:()=> 'DEVICE',newRequestId:()=> 'REQUEST',verificationRequestId:()=> 'REQUEST',rpcWithRetry:async()=>({data:{ok:accepted,result:accepted?'LIMITED':'DENIED'}}),normalizeRpcData:x=>x,setResult:()=>{rendered=true;if(accepted)assert(saved);},showManualSections:()=>{},setAutoDevicePanel:()=>{},window:{ALBASHIRAccess:{setSession:(role,extra)=>{assert(!rendered);saved={role,...extra};return saved;}}}};
vm.createContext(c);vm.runInContext(source,c);await c.submitEmployeeVerification();assert.equal(!!saved,accepted);if(accepted)assert.equal(saved.rememberMe,remember);
}
console.log('PASS successful QR manual verification remembers before photo render; opt-out preserved; denied never remembered');
})().catch(e=>{console.error(e);process.exitCode=1});
