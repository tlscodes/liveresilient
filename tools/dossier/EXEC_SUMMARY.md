# خلاصه‌ی اجرایی — voice_call_kit، وضعیت اندازه‌گیری‌شده

هر عدد این صفحه منبع TSV/لاگ دارد؛ چیزی از حافظه یا اینترنت نقل نشده. ‹src:tools/dossier/manifest.tsv›

## آنچه ثابت شده

- شش قابلیت پیام‌رسانی با بایت سیمِ اندازه‌گیری‌شده، همه سبز؛ بازتأیید
  مکانیکی دوباره سبز. ‹src:tools/phase5/h3_results.tsv›
- کل درخت کد: ۷۴ ردیف بررسی/تست، صفر شکست. ‹src:tools/dossier/logs/full_tree_summary.tsv›
- زیرسیستم دفاع در برابر پروب با گیت‌های خودش: صفر گیتِ بی‌مدرک، صفر
  بلاک. ‹src:tools/dossier/logs/probe_defense_gate.log›
- هفت کتابخانه‌ی نیتیو برای iOS با کامیت و هش پین‌شده؛ اپ Release با
  همه‌ی آن‌ها روی دستگاه واقعی بوت شد. ‹src:tools/phase5/native/ios/PROVENANCE.tsv و tools/dossier/logs/ios_boot_verified.done›
- اتصال FFI با مدیریت حافظه‌ی finalizer و تستِ بدون-کرش. ‹src:tools/dossier/logs/ffi_finalizer_test.log›

## ماتریس دستگاه زیر پروفایل سخت

پروفایل: پهنای 2Kbps در هر عبور، اتلاف سرجمع 60 درصد، rtt=2000ms. ‹src:tools/dossier/logs/e2e_netshape.log›
نتیجه‌ی رسمی در جدول زیر است و هر ادعای این خلاصه به همان محدود می‌ماند:

```
tools/dossier/e2e_ios_results.tsv
```

## شکاف اعلام‌شده

لاین دیتاگرام هنوز رمزنگاری سرتاسری ندارد؛ نقشه‌ی بستنش با سنجه‌ی پذیرش
در فصل ۷ سند فنی آمده و در پروپوزال «تعهد طراحی» است، نه ادعای موجود. ‹src:tools/dossier/TECH_DOSSIER.md›

## سه سند همراه

```
TECH_DOSSIER.md        سند فنی با فصل صادق رمزنگاری
PROPOSAL_SKELETON.md   اسکلت پروپوزال، جای‌خالی‌های [مالک]
reproduce_conditions.sh بازتولید شرایط برای داور بیرونی
```
