#!/usr/bin/env python3
"""Bake-off: 5 on-device candidates against one hard composite scenario.

The scenario mirrors the reference app's real job (offline connectivity
assistant): judge a degrading multi-lane snapshot, narrate it in plain
Persian, order an offline backlog, reason about a latency-vs-loss trap,
and emit strict JSON for the UI. Scoring is mechanical (substring/parse
checks), timing comes from ollama's own token counters.
"""
import json
import re
import sys
import time
import urllib.request

MODELS = ["smollm2:135m", "gemma3:270m", "qwen3:0.6b", "gemma3:1b", "qwen3:1.7b"]

SNAPSHOT = {
    "mode": "live",
    "lanes": [
        {"id": "wifi:CafeNet", "score": 0.62, "slope_per_s": -0.04, "rtt_ms": 120, "loss_pct": 2.0},
        {"id": "cell:Irancell", "score": 0.55, "slope_per_s": 0.01, "rtt_ms": 300, "loss_pct": 0.5},
        {"id": "local_mesh", "score": 0.30, "slope_per_s": 0.0, "rtt_ms": 40, "loss_pct": 8.0},
    ],
    "pending_bundles": 12,
}

BACKLOG = [
    {"id": "m1", "priority": "bulk", "kind": "photo"},
    {"id": "m2", "priority": "urgent", "kind": "voice-note"},
    {"id": "m3", "priority": "bulk", "kind": "photo"},
    {"id": "m4", "priority": "normal", "kind": "text"},
    {"id": "m5", "priority": "urgent", "kind": "text"},
]

TASKS = [
    {
        "name": "T1-judgment",
        "prompt": (
            "You are the connectivity brain of a messaging app. Snapshot: "
            + json.dumps(SNAPSHOT)
            + "\nThe wifi lane is best now but its score slope is -0.04/s (sliding). "
            "Which single lane should be pre-warmed as fallback BEFORE wifi fails, "
            "and why in one sentence? Answer with the lane id first."
        ),
        "check": lambda t: ("cell" in t.lower() or "irancell" in t.lower()) and "mesh" not in t.lower().split("\n")[0],
    },
    {
        "name": "T2-persian",
        "prompt": (
            "وضعیت شبکه: وای‌فای در حال ضعیف شدن است، ۱۲ پیام در صف ذخیره شده‌اند و بعداً ارسال می‌شوند. "
            "در حداکثر دو جملهٔ فارسیِ ساده و آرام برای کاربر توضیح بده؛ عدد ۱۲ حتماً بیاید؛ اصطلاح فنی ممنوع."
        ),
        "check": lambda t: ("۱۲" in t or "12" in t) and len(re.findall(r"[.!؟۔]", t)) <= 4,
    },
    {
        "name": "T3-backlog",
        "prompt": (
            "Offline queue: " + json.dumps(BACKLOG)
            + "\nOn reconnect, which two message ids must send FIRST? Reply with just the two ids."
        ),
        "check": lambda t: "m2" in t and "m5" in t and "m1" not in t.replace("m1", "", 0),
    },
    {
        "name": "T4-tradeoff",
        "prompt": (
            "For a live VOICE call, lane A: rtt 120ms, loss 2%; lane B: rtt 300ms, loss 0.5%. "
            "Which lane is better for the call and why, in two sentences max?"
        ),
        "check": lambda t: bool(re.match(r"^\W*(lane\s*)?a\b", t.strip(), re.I)) and ("300" in t or "latency" in t.lower() or "delay" in t.lower() or "تاخیر" in t or "تأخیر" in t),
    },
    {
        "name": "T5-json",
        "prompt": (
            "Emit ONLY a JSON object, no prose, no code fence: keys level (one of calm|caution|critical), "
            "headline_fa (short Persian sentence), action (snake_case verb phrase). "
            "Situation: wifi sliding, fallback being pre-warmed."
        ),
        "check": lambda t: _json_ok(t),
    },
]


def _json_ok(t: str) -> bool:
    m = re.search(r"\{.*\}", t, re.S)
    if not m:
        return False
    try:
        d = json.loads(m.group(0))
    except json.JSONDecodeError:
        return False
    return d.get("level") in {"calm", "caution", "critical"} and bool(d.get("headline_fa")) and bool(d.get("action"))


def ask(model: str, prompt: str) -> tuple[str, float, float]:
    req_body = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.2, "num_predict": 300},
    }
    if model.startswith("qwen3"):
        req_body["think"] = False  # reasoning mode eats the whole token budget
    body = json.dumps(req_body).encode()
    req = urllib.request.Request("http://localhost:11434/api/generate", data=body)
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
    wall = time.time() - t0
    toks = d.get("eval_count", 0)
    secs = d.get("eval_duration", 1) / 1e9
    text = d.get("response", "")
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)  # qwen3 thinking
    return text.strip(), wall, (toks / secs if secs else 0)


def main() -> None:
    results = {}
    for model in MODELS:
        print(f"\n===== {model} =====", flush=True)
        score, speed_sum, n = 0, 0.0, 0
        for task in TASKS:
            try:
                text, wall, tps = ask(model, task["prompt"])
            except Exception as e:  # noqa: BLE001
                print(f"  {task['name']}: ERROR {e}")
                continue
            ok = False
            try:
                ok = task["check"](text)
            except Exception:  # noqa: BLE001
                ok = False
            score += int(ok)
            speed_sum += tps
            n += 1
            print(f"  {task['name']}: {'PASS' if ok else 'fail'}  ({wall:.1f}s, {tps:.1f} tok/s)")
            print("    " + text[:180].replace("\n", " ") + ("…" if len(text) > 180 else ""))
        results[model] = {"score": score, "avg_tok_s": round(speed_sum / max(n, 1), 1)}
    print("\n===== FINAL =====")
    for m, r in sorted(results.items(), key=lambda kv: (-kv[1]["score"], -kv[1]["avg_tok_s"])):
        print(f"{m:15s} score {r['score']}/5   {r['avg_tok_s']} tok/s")
    json.dump(results, open(sys.argv[1] if len(sys.argv) > 1 else "/dev/null", "w"), indent=1)


if __name__ == "__main__":
    main()
