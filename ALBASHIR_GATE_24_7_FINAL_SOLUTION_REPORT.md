# التقرير النهائي للحلول والإنتاج
# ALBASHIR Gate 24/7

تاريخ آخر تحديث: 2026-10-05

المشروع:
ALBASHIR Emergency Hospital Gate

Repository:
KISSCRISIS/albashir-stone-karag

Production Branch:
main

Production Platform:
Vercel

Production URL:
https://albashir-stone-karag.vercel.app

Backend:
Supabase

Production Supabase Project:
ALBASHIR-Gate-Production2026

Project Reference:
qinsfvlspdticposbvst

---

# 1. حالة المشروع الحالية

النظام عبارة عن تطبيق Static Web Application مبني باستخدام:

- HTML5
- CSS3
- Vanilla JavaScript
- Supabase JavaScript Client
- Service Worker / PWA
- IndexedDB
- LocalStorage
- Supabase Database
- Supabase RPC
- Supabase Realtime

لا يعتمد المشروع على:

- Next.js
- React
- Vue
- Build Framework

ولا توجد حاجة إلى Framework migration في المرحلة الحالية.

النشر الرسمي الحالي يتم من فرع:

main

إلى:

Vercel

أي نسخة موجودة سابقاً على Netlify لم تعد مرجع الإنتاج الرسمي.

---

# 2. مسار الإنتاج المعتمد

المسار الرسمي للنظام:

GitHub main

↓

Vercel

↓

https://albashir-stone-karag.vercel.app

↓

Supabase

↓

qinsfvlspdticposbvst

Vercel هو منصة الـFrontend Production الرسمية.

Supabase هو Backend Production الرسمي.

---

# 3. إلغاء الاعتماد على Netlify

تم اعتماد Vercel كمنصة الإنتاج الرسمية بدلاً من Netlify.

يجب ألا يحتوي الكود التشغيلي على روابط ثابتة إلى:

sprightly-donut-6db8c8.netlify.app

أي رابط داخلي يجب أن يعتمد على:

window.location.origin

كلما أمكن ذلك.

الهدف من ذلك:

- منع ربط النظام بمنصة استضافة قديمة.
- دعم تغيير الدومين مستقبلاً.
- دعم Custom Domain بدون تعديل الكود.
- منع نسخ روابط التسجيل أو التحقق من نطاق قديم.

ملفات إعداد Netlify القديمة مثل:

netlify.toml

لم تعد مطلوبة في بيئة الإنتاج الحالية ويمكن حذفها بعد التأكد من اكتمال الانتقال إلى Vercel.

Netlify لا يعتبر بعد الآن Production Source of Truth.

---

# 4. Supabase Production

Production Project:

ALBASHIR-Gate-Production2026

Reference:

qinsfvlspdticposbvst

Project URL:

https://qinsfvlspdticposbvst.supabase.co

الواجهة الأمامية تتصل مباشرة بـ Supabase باستخدام Publishable / Anon Key.

مهم:

الحماية الفعلية لا تعتمد على إخفاء الـPublishable Key، وإنما تعتمد على:

- Row Level Security
- RPC authorization
- Authentication
- Device authorization
- Trusted Device validation
- Server-side database rules

يجب عدم استخدام Service Role Key داخل ملفات HTML أو JavaScript العامة.

---

# 5. صفحات النظام الرئيسية

## portal.html

الصفحة العامة والبوابة الرئيسية للنظام.

تستخدم لعرض:

- هوية مستشفى البشير.
- النظام.
- خيارات الدخول.
- القيادة الإدارية.
- روابط الوصول إلى النظام.

---

## index.html

شاشة تشغيل البوابة والحارس الخاصة بتوليد QR.

المهام:

- التحقق من جهاز البوابة.
- إنشاء QR Session.
- تحديث QR.
- Device heartbeat.
- Device approval status.
- QR lifecycle.

---

## login.html

بوابة تسجيل الدخول الموحدة.

تستخدم لـ:

- الموظفين.
- الحراس.
- الإدارة.

---

## register.html

صفحة تسجيل الموظف.

تشمل:

- الصورة.
- الاسم.
- الرقم الوظيفي أو البيانات التعريفية.
- رقم الهاتف.
- المسمى الوظيفي.
- القسم.
- التخصص.
- بيانات الجهاز الموثوق.
- الإقرارات المطلوبة.

---

## profile.html

بوابة الموظف الشخصية.

تشمل:

- بيانات الموظف.
- حالة الحساب.
- حالة الجهاز.
- الصلاحيات.
- سجل الاستخدام.
- Trusted Device.

---

## verify.html

صفحة التحقق عبر QR.

وظيفتها الأساسية:

- فتح الكاميرا.
- قراءة QR.
- إرسال طلب التحقق.
- عرض نتيجة الدخول.

لا يجب استخدامها كلوحة بحث عن الموظفين.

---

## guard.html

واجهة التحقق المخصصة للحارس.

الحارس:

- يقوم بالمسح.
- يشاهد النتيجة.
- يشاهد بيانات الموظف المطلوبة فقط.

الحارس لا يجب أن:

- يعدل الموظفين.
- يبحث في قاعدة الموظفين.
- يغير الصلاحيات.
- يعتمد الأجهزة.

---

## admin_dashboard.html

لوحة الإدارة.

تشمل:

- إدارة الموظفين.
- اعتماد الطلبات.
- اعتماد الأجهزة.
- مراقبة Gate Devices.
- Audit Logs.
- Access Logs.
- التقارير.
- إعدادات النظام.

---

# 6. P0 — QR Stability

الحالة:

منفذ

تم تنفيذ التصحيحات الأساسية الخاصة باستقرار QR.

السلوك الحالي:

- حفظ آخر QR صالح.
- حفظ token.
- حفظ expiresAt.
- عدم حذف QR صالح عند فشل طلب التجديد.
- عدم إنشاء Public QR fallback غير موثق.
- منع تداخل طلبات QR.
- Retry / Backoff.

القيم المستخدمة:

2s

→

5s

→

15s

→

30s

يتم الاعتماد على:

expires_in_seconds

القادم من:

create_qr_session

بدلاً من عداد ثابت غير مرتبط بالخادم.

---

# 7. QR Failure Handling

في حال تعذر إنشاء QR جديد:

إذا كان آخر QR ما زال صالحاً:

يستمر عرضه حتى انتهاء صلاحيته.

إذا انتهى QR ولم يستطع النظام إنشاء QR جديد:

يجب أن تظهر حالة:

System unavailable

أو:

Connection error

ولا يجب إنشاء QR غير موثق.

---

# 8. QR Watchdog

يتم مراقبة نجاح عملية تحديث QR.

إذا تأخر آخر نجاح بشكل غير طبيعي:

يتم محاولة إعادة تشغيل دورة QR.

الهدف:

منع بقاء شاشة الحارس معلقة لساعات بدون QR صالح.

---

# 9. QR Cleanup

تمت إضافة:

public.cleanup_expired_qr_sessions()

الهدف:

تنظيف QR Sessions القديمة والمنتهية.

لا يجب تحميل عملية تنظيف الجلسات القديمة على:

create_qr_session

في كل طلب.

يوصى بتشغيل:

cleanup_expired_qr_sessions()

دورياً.

مثال:

كل 10 إلى 30 دقيقة.

عبر:

Supabase Cron

أو:

Scheduled Function

---

# 10. Database Indexes

تمت إضافة Index لتحسين البحث عن الموظفين.

```sql
create index if not exists idx_employee_registrations_employee_mobile
on public.employee_registrations(employee_id, mobile_number);
