import { withSupabase } from 'npm:@supabase/server@1.9.1';
import webpush from 'npm:web-push@3.6.7';

// A publishable project key plus a separate server-only dispatch credential.
// The credential authorizes only the bounded notice outbox RPCs, not table access.
export default {
  fetch: withSupabase({ auth: 'publishable' }, async (request, ctx) => {
    if (request.method !== 'POST') return new Response(null,{status:405});
    const key=request.headers.get('x-dispatch-key');
    if (!key || !/^[a-f0-9]{64}$/.test(key)) return new Response(null,{status:403});
    const {data,error}=await ctx.supabase.rpc('admin_notice_claim',{p_key:key});
    if(error) return Response.json({ok:false},{status:503});
    if(data?.ok!==true) return new Response(null,{status:403});
    if(!data.vapid_public||!data.vapid_private) return Response.json({ok:false},{status:503});
    let delivered=0;
    for(let offset=0;offset<data.jobs.length;offset+=5) {
      await Promise.all(data.jobs.slice(offset,offset+5).map(async(job: {id:string;subscription:{endpoint:string;keys:{auth:string;p256dh:string}};title:string;body:string;event_id:string;target:string})=>{
        let code=500;
        try {
          const url=new URL(job.subscription.endpoint);
          if(url.protocol!=='https:'||url.port||url.username||url.password||!(new Set(['fcm.googleapis.com','updates.push.services.mozilla.com','web.push.apple.com']).has(url.hostname)||/^[a-z0-9-]+\.notify\.windows\.com$/.test(url.hostname))) throw Error('Invalid endpoint');
          const response=await webpush.sendNotification(job.subscription,JSON.stringify({title:job.title,body:job.body,event_id:job.event_id,target:job.target}),{
            TTL:300,timeout:6000,urgency:'normal',vapidDetails:{subject:'mailto:kisscrisis@list.ru',publicKey:data.vapid_public,privateKey:data.vapid_private}
          });
          code=response.statusCode;if(code>=200&&code<300)delivered++;
        }catch(err){code=Number((err as {statusCode?:number}).statusCode)||500;}
        const result=await ctx.supabase.rpc('admin_notice_complete',{p_key:key,p_id:job.id,p_status:code});
        if(result.error) console.error('Notice receipt could not be saved');
      }));
    }
    return Response.json({ok:true,claimed:data.jobs.length,delivered});
  })
};
