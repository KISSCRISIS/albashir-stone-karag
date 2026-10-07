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
