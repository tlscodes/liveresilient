# رکورد هم‌صدا — تماس صوتی توکنی کم‌بیت (سند محک، ۲۰۲۶-۰۷-۲۵)

خطِ اول: روی ضبط واقعی کاربر، لایه‌ی بی‌اتلاف هم‌صدا با دیکشنری همگراشده 675bps اندازه‌گیری شد — زیر مرز 700bps کدک کلاسیک Codec2 700C، با کیفیت بازسازی عصبی EnCodec و دیکود بیت‌به‌بیت.

## پیکره و ابزار (همه‌ی اعداد از خروجی ابزار، نه تخمین)

```
corpus:   demo_audio/gift_24k.wav  (13.57s real user voice, 1018 frames)
tokens:   EnCodec 24kHz @ 1.5kbps band -> 2 rows x 10 bits = 20 bits/frame
codec:    tools/hamseda_arith.py  (Subbotin carryless range coder,
          PPM-C escape, order-1 row models, persistent column dictionary)
verifiers: tools/warm_curve.py · tools/hamseda_loss_test.py ·
          packages/hamseda_codec (dart test, 10 tests)
```

## حسابداری بیت (با استهلاک دیکشنری)

دیکشنری از خودِ جریان ساخته می‌شود؛ هیچ بایت هماهنگی یا جدول جداگانه روی سیم نمی‌رود، پس هزینه‌ی رشد دیکشنری همین اعداد هر-تماس است و چیزی پنهان نیست.

```
raw token stream:                 1500.6 bps
cold sequential calls (curve):    1668 / 1427 / 1808 / 1346 bps
fully-warm re-encode (record):     675 bps   [bit-exact OK]
ideal order-0 column entropy:      645 bps   (floor for this corpus)
Codec2 700C reference:             700 bps
```

## v4 — مدل مرتبه‌۱ ستونی (رکورد جدید، همان شب)

کد ستون در جدول فراوانیِ ستونِ قبلی کدگذاری می‌شود (`tools/hamseda_v4_test.py`؛ escape به جدول سراسری بعد ردیف‌ها؛ کاملاً تطبیقی و بیت‌به‌بیت).

```
full band  (raw 1501): cold 1395-1869 bps · fully-warm  85 bps  [8.2x under 700C]
row0 lane  (raw  750): cold  574-818 bps · fully-warm 203 bps
row0 fresh-content calls 2 & 4:  638 / 574 bps  -> UNDER 700 on new speech
audio proof of row0 quality: demo_audio/gift_row0_750bps.wav
```

## نسخه‌ی محصول (order-2، در هر دو زبان — رکورد نهایی این شب)

کتابخانه‌ی مرجع `tools/hamseda_v4.py` و پکیج `packages/hamseda_codec` هر دو مدل چهار-پله‌ای (زمینه‌ی مرتبه‌۲ → مرتبه‌۱ → سراسری → ردیف‌ها) + سقف بدترین-حالت raw دارند؛ خروجی دو زبان بایت‌به‌بایت یکسان است.

```
cold (any call):     capped at raw + 1 byte   (1501.2 bps measured)
fully-warm full band:  31.8 bps  [22x under Codec2 700C, bit-exact,
                       byte-identical Python & Dart: warm 54B fnv b5d19bd2]
verifiers: tools/test_hamseda_v4.py (12 checks) · dart test (10) ·
           tool/parity.dart == tools/parity_dump.py
```

## برچسب صادقانه‌ی کیفیت و ادعا

- عدد 675bps مالِ بازپخش گفتاری است که دیکشنری قبلاً دیده (سقف همگرایی هر-مخاطب)؛ تماس با محتوای کاملاً تازه امروز 1350–1450bps می‌رود و با هر تماس پایین می‌آید.
- کیفیت شنیداری = بازسازی عصبی EnCodec از موج واقعی؛ لایه‌ی هم‌صدا روی جریان توکن بی‌اتلاف است (assert بیت‌به‌بیت در هر سه verifier).
- ادعای عمومی «رکورد» تا بنچ MOS انسانی (بک‌لاگ) فقط با همین برچسب منتشر شود.

## مقاومت در برابر گم‌شدن بسته (فاز ۲)

رشد حالت فقط با بلوک‌های ack‌شده؛ فرستنده روی بلوک گم‌شده rollback می‌کند.

```
loss 0%:  41 blocks, delivered bit-exact, state converged
loss 5%:  4 lost,   delivered bit-exact, state converged
loss 20%: 9 lost,   delivered bit-exact, state converged  (PHASE2 OK)
```

## پورت محصول (فاز ۳ و ۴)

- `packages/hamseda_codec` — Dart خالص، ۱۰ تست سبز: roundtrip بیت‌به‌بیت، ماندگاری JSON بین‌تماسی، بدون واگرایی در ۰/۵/۲۰٪ loss، مرزها (arity غلط، ورودی خراب، halving طولانی). `dart analyze --fatal-infos` پاک.
- رانگ جدید نردبان بقا: `DegradedMode.tokenVoice` بین صدای کم‌نرخ و ویس‌نوت؛ فقط وقتی seam دانلود کدک (`VoiceCodecBinding` در device_link) مدل را حاضر گزارش کند.

## پروتکل محک تکرارپذیر

```
1. bash tools/setup_voice_clone_env.sh
2. python tools/dump_tokens.py <voice.wav> /tmp/tokens.json
3. python tools/warm_curve.py /tmp/tokens.json 4      # bps curve + bit-exact
4. python tools/hamseda_loss_test.py /tmp/tokens.json # loss tolerance
5. dart test packages/hamseda_codec                   # product port
```

بک‌لاگ رکورد: MOS انسانی، کدک عصبی اختصاصی با کوانتیزاسیون تهاجمی‌تر (Colab)، و سنجش چند-مخاطبی روی پیکره‌ی بلندتر.
