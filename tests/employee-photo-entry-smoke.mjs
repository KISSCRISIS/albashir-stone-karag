// Local Deno entry-point smoke test. No real Supabase credentials or calls.
const originalServe = Deno.serve;
let server;
Deno.serve = handler => {
  server = originalServe({hostname: '127.0.0.1',port: 8000},handler);
  return server;
};
try {
  await import('../supabase/functions/employee-photo-url/index.ts');
  const headers={origin:'http://127.0.0.1:8000'};
  const preflight=await fetch('http://127.0.0.1:8000',{method:'OPTIONS',headers});
  if(preflight.status!==204) throw Error('Preflight failed');
  await preflight.arrayBuffer();
  const denied=await fetch('http://127.0.0.1:8000',{
    method:'POST',headers:{...headers,'content-type':'application/json'},
    body:JSON.stringify({action:'resolve',path:'registrations/SYN-A/a.jpg',actor:{}})
  });
  if(denied.status!==403) throw Error('Anonymous request was not denied');
  const body=await denied.json();
  if(JSON.stringify(body)!==JSON.stringify({ok:false,error:'DENIED'})) throw Error('Denial exposed unexpected fields');
  console.log('PASS actual Deno entry, CORS preflight and opaque anonymous denial; local network only');
} finally {
  if(server) await server.shutdown();
}
