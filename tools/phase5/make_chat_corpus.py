#!/usr/bin/env python3
"""Deterministic chat corpus generator for phase 5 gate 1.

Writes two JSONL files into tools/phase5/corpus/:
  chat_corpus_200.jsonl   eval set, 200 messages, seed 53  (gate 1 measures THIS)
  chat_train_2000.jsonl   dict-training set, 2000 messages, seed 54
Train and eval come from the same template pools with different seeds, so the
zstd dictionary learns common substrings, never the exact eval strings.
"""
import json
import random
from pathlib import Path

FA_SHORT = [
    "سلام", "سلام خوبی؟", "کجایی؟", "اومدم", "باشه", "مرسی", "قربونت",
    "الان زنگ می‌زنم", "بعدا حرف می‌زنیم", "رسیدم خونه", "دارم میام",
    "گوشیم شارژ نداره", "صدات قطع و وصل میشه", "آنتن ندارم", "شب بخیر",
    "صبح بخیر", "چه خبر؟", "هیچی سلامتی", "فعلا", "خداحافظ", "دمت گرم",
    "جانم؟", "بگو", "نت ندارم", "با وایفای وصل شدم",
]
FA_MED = [
    "امشب ساعت {h} تماس بگیریم؟ اینترنت اینجا خیلی ضعیفه",
    "پیام صوتی فرستادم ولی فکر نکنم رسیده باشه، دوباره می‌فرستم",
    "اگه تونستی اون عکس رو دوباره بفرست، این‌بار با کیفیت پایین‌تر",
    "فردا ساعت {h} جلسه داریم، یادت نره لینک رو بفرستی",
    "این هفته خیلی سرم شلوغه، شاید {d} بتونیم همدیگه رو ببینیم",
    "مامان گفت شام بیاید خونه‌ی ما، به {name} هم بگو",
    "تو راهم، ترافیک سنگینه، فکر کنم {m} دقیقه دیگه برسم",
    "صدای تماس دیشب خیلی خوب بود، اصلا قطع نشد",
    "برنامه رو آپدیت کردی؟ نسخه‌ی جدیدش خیلی کم‌حجم‌تره",
    "بلیت قطار برای {d} گرفتم، ساعت {h} حرکت می‌کنه",
]
FA_LONG = [
    "دیروز رفتم بازار برای عید خرید کنم، انقدر شلوغ بود که نگو، آخرش هم نصف چیزهایی که می‌خواستم پیدا نکردم، حالا باید {d} دوباره برم، اگه خواستی باهام بیا",
    "راستش این چند وقت اینترنت انقدر بد شده که تماس تصویری اصلا وصل نمیشه، فقط پیام متنی جواب میده، اگه شد یه پیام صوتی کوتاه بفرست ببینم صدات میاد یا نه",
    "برای پروژه‌ی دانشگاه باید تا {d} گزارش رو تحویل بدم، هنوز نصفش مونده، امشب تا دیروقت بیدارم، اگه سوالی داشتم بهت پیام میدم، ممنون که کمکم می‌کنی",
]
EN_SHORT = [
    "hi", "hey there", "ok", "sure", "thanks!", "on my way", "call me",
    "sorry, bad signal", "can you hear me?", "gtg", "brb", "good night",
    "morning!", "what's up?", "np", "see you", "done", "sent it", "got it",
    "lol", "no worries", "one sec",
]
EN_MED = [
    "meeting moved to {h}:00, check the calendar invite",
    "the voice note didn't come through, resend it please",
    "my data plan is almost gone, switch to text for now",
    "landing at {h}pm, will text you from the airport",
    "the new build is much smaller, update when you can",
    "send the photo in low quality, connection is terrible here",
    "let's do the call on {d}, same time as last week",
    "battery at {m}%, might drop off the call soon",
]
EN_LONG = [
    "just got back from the trip, the mountain roads had zero coverage for two days so all my messages queued up, sending you the photos in small size now, tell me which ones you want in full resolution",
    "the demo went well but the venue wifi was awful, the fallback to low-bitrate voice actually saved us, we should make that the default when the link drops below a threshold",
]
MIX = [
    "سلام، فایل report_final.pdf رو فرستادم چک کن",
    "اون لینک meet.example.com/abc رو دوباره بفرست",
    "ساعت {h} تو Zoom باش، آیدی همونه",
    "ورژن 2.4.1 رو نصب کن، باگ قبلی fix شده",
    "قرارمون ساعت {h} کافه‌ی همیشگی، ok؟",
    "قیمتش {m}00 تومنه با تخفیف، okay؟",
]
EMOJI = ["", "", "", " 🙂", " 😂", " ❤️", " 👍", " 🙏", " 😅", ""]
NAMES = ["رضا", "مریم", "علی", "سارا", "نیما", "لیلا"]
DAYS = ["شنبه", "یکشنبه", "دوشنبه", "پنجشنبه", "جمعه", "آخر هفته"]


def fill(t: str, rng: random.Random) -> str:
    return (
        t.replace("{h}", str(rng.randint(1, 23)))
        .replace("{m}", str(rng.randint(10, 59)))
        .replace("{d}", rng.choice(DAYS))
        .replace("{name}", rng.choice(NAMES))
    )


def gen(n: int, seed: int):
    rng = random.Random(seed)
    out = []
    for i in range(n):
        r = rng.random()
        if r < 0.40:
            lang, pool = rng.choice([("fa", FA_SHORT), ("en", EN_SHORT)])
        elif r < 0.80:
            lang, pool = rng.choice([("fa", FA_MED), ("en", EN_MED), ("mix", MIX)])
        else:
            lang, pool = rng.choice([("fa", FA_LONG), ("en", EN_LONG)])
        text = fill(rng.choice(pool), rng) + rng.choice(EMOJI)
        out.append({"id": i, "lang": lang, "text": text})
    return out


def write(path: Path, rows):
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    corpus_dir = Path(__file__).resolve().parent / "corpus"
    corpus_dir.mkdir(parents=True, exist_ok=True)
    write(corpus_dir / "chat_corpus_200.jsonl", gen(200, 53))
    write(corpus_dir / "chat_train_2000.jsonl", gen(2000, 54))
    print("wrote chat_corpus_200.jsonl and chat_train_2000.jsonl")
