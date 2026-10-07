const fs=require("fs"),path=require("path"),assert=require("assert/strict");
const root=path.resolve(__dirname,"..");
const html=fs.readFileSync(path.join(root,"register.html"),"utf8");
const migration=fs.readFileSync(path.join(root,"supabase/migrations/20261007160500_registration_taxonomy_permanent_departments.sql"),"utf8");
for(const value of [
"الإسعاف والطوارئ (DRS/NRS/EMT/MLT)","أطباء امتياز","ممرضو رعاية حثيثة (ICU)",
"فنيو أشعة وتصوير طبي","فنيو مختبرات طبية","صيادلة ومساعدو صيادلة","مسعفون",
"موظفو سجلات طبية واستعلامات","موظفو محاسبة ودخول","مدخلو بيانات","كوادر أمن وحماية",
"عمال خدمات ونظافة","أخرى"]) {
  assert(html.includes(`<option>${value}</option>`) || html.includes(`<option value="${value}">${value}</option>`),`missing permanent department: ${value}`);
  assert(migration.includes(`normalize_specialty_name('${value}')`),`backend permanent allowlist missing: ${value}`);
}
assert(!html.includes('<option>طب عام</option>\n          <option>جراحة عامة</option>\n          <option>باطني</option>\n          <option>أطفال</option>\n          <option>ENT</option>\n          <option>نسائية</option>\n          <option>مسالك بولية</option>\n          <option>عيون</option>\n          <option>جراحة دماغ وأعصاب</option>\n          <option>تخدير</option>\n          <option>جراحة أوعية دموية</option>\n          <option>أشعة</option>\n          <option>مختبرات</option>\n          <option>صيانة</option>\n          <option>إدارة</option>\n          <option>أمن</option>\n          <option>أخرى</option>\n        </select>\n      </div>\n\n      <div id="specialtyWrap">'),"legacy permanent department list must be removed");
assert(html.includes('id="employeeIdType"'),"temporary registration must choose national or employee ID type");
assert(html.includes('<option value="NATIONAL">رقم وطني</option>'));
assert(html.includes('<option value="EMPLOYEE">رقم وظيفي</option>'));
const specialty=html.slice(html.indexOf('id="specialty"'),html.indexOf('id="affiliatedEntityWrap"'));
assert(!specialty.includes("الإسعاف والطوارئ"),"temporary specialty must not include emergency department");
assert(!specialty.includes(">طب عام<"),"temporary specialty must not include general medicine");
for(const value of ["جراحة عامة","باطني","أطفال","ENT","نسائية","مسالك بولية","عيون","جراحة دماغ وأعصاب","تخدير","جراحة أوعية دموية","أشعة","مختبرات","صيانة","إدارة","أمن","أخرى"]) assert(specialty.includes(`>${value}<`),`temporary specialty missing ${value}`);
for(const value of ["مستشفى الجراحة والجراحات التخصصية","مستشفى النسائية والتوليد والأطفال","مستشفى الباطني والأشعة والجلدية: العناية القلبية وغسيل الكلى","مستشفى الأورام والأشعة العلاجية","أمن","صيانة","عيادات"]) assert(html.includes(`<option>${value}</option>`),`affiliation missing ${value}`);
assert(html.includes('<option value="OTHER">أخرى</option>'));
assert(html.includes('id="affiliatedEntityOther"'));
assert(html.includes("selectedAffiliatedEntity()"),"custom affiliation must be sent to registration RPC");
console.log("PASS registration taxonomy and permanent department policy");
