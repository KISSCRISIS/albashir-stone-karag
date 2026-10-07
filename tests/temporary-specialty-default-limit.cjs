const fs=require("fs"),path=require("path"),assert=require("assert/strict");
const root=path.resolve(__dirname,"..");
const sql=fs.readFileSync(path.join(root,"supabase/migrations/20261007162500_seed_temporary_specialty_limits_7.sql"),"utf8");
const html=fs.readFileSync(path.join(root,"register.html"),"utf8");
const specialty=html.slice(html.indexOf('id="specialty"'),html.indexOf('id="affiliatedEntityWrap"'));
const expected=["جراحة عامة","باطني","أطفال","ENT","نسائية","مسالك بولية","عيون","جراحة دماغ وأعصاب","تخدير","جراحة أوعية دموية","أشعة","مختبرات","صيانة","إدارة","أمن","أخرى"];
for(const name of expected){
  assert(specialty.includes(`>${name}<`),`registration specialty missing ${name}`);
  assert(sql.includes(`('${name}', 7, true)`),`default limit missing ${name}`);
}
assert(sql.includes("on conflict (specialty_name) do update"));
assert(sql.includes("daily_limit = excluded.daily_limit"));
assert(sql.includes("is_active = excluded.is_active"));
console.log("PASS temporary/external registration specialties default to 7/day and remain admin-editable");
