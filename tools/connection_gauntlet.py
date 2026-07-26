#!/usr/bin/env python3
"""Connection gauntlet: a 15-step multi-factor crisis simulation.

Each step presents the live lane table (up/down, rtt, loss, trend) plus
recent history. The decision agent must answer with strict JSON:
  {"send_via": "<lane-id>"} to transmit now, or {"send_via": "queue"}
to hold the message for later flush.

Ground truth per step: a transmission succeeds only on a lane that is up
with loss < 20%. Queued messages auto-flush at the next step where any
usable lane exists (that is what the app's store-and-forward does).

Scoring (mechanical):
  +2 delivered live this step
  +1 correctly queued when NOTHING was usable
  -2 sent into a dead/unusable lane (message lost -> retry later)
  -1 needlessly queued while a usable lane existed (latency cost)
  -1 each lane switch beyond 4 total (thrash penalty)

A deterministic BASELINE (the app's actual planner rule: best usable
lane by score, else queue) runs alongside the models for reference.
"""
import json
import re
import sys
import time
import urllib.request

# ---- the crisis timeline: (description, lanes) ------------------------------
# lane: id, up, rtt_ms, loss_pct, trend (falling|flat|rising), score
STEPS = [
    ("calm start", [
        ("wifi", True, 45, 0.5, "flat", 0.9), ("cell", True, 180, 1.0, "flat", 0.6), ("link", False, 0, 100, "flat", 0.0)]),
    ("wifi begins to slide", [
        ("wifi", True, 90, 2.0, "falling", 0.7), ("cell", True, 180, 1.0, "flat", 0.6), ("link", False, 0, 100, "flat", 0.0)]),
    ("wifi sliding hard", [
        ("wifi", True, 300, 8.0, "falling", 0.45), ("cell", True, 190, 1.2, "flat", 0.6), ("link", False, 0, 100, "flat", 0.0)]),
    ("wifi dies", [
        ("wifi", False, 0, 100, "falling", 0.0), ("cell", True, 200, 1.5, "flat", 0.6), ("link", False, 0, 100, "flat", 0.0)]),
    ("cell flaps down", [
        ("wifi", False, 0, 100, "flat", 0.0), ("cell", False, 0, 100, "falling", 0.1), ("link", False, 0, 100, "flat", 0.0)]),
    ("total blackout", [
        ("wifi", False, 0, 100, "flat", 0.0), ("cell", False, 0, 100, "flat", 0.0), ("link", False, 0, 100, "flat", 0.0)]),
    ("nearby device appears (link only)", [
        ("wifi", False, 0, 100, "flat", 0.0), ("cell", False, 0, 100, "flat", 0.0), ("link", True, 60, 12.0, "flat", 0.35)]),
    ("link only, high loss", [
        ("wifi", False, 0, 100, "flat", 0.0), ("cell", False, 0, 100, "flat", 0.0), ("link", True, 70, 15.0, "flat", 0.3)]),
    ("link degrades past usable", [
        ("wifi", False, 0, 100, "flat", 0.0), ("cell", False, 0, 100, "flat", 0.0), ("link", True, 90, 35.0, "falling", 0.15)]),
    ("cell flickers back weak", [
        ("wifi", False, 0, 100, "flat", 0.0), ("cell", True, 350, 4.0, "rising", 0.4), ("link", True, 90, 30.0, "flat", 0.15)]),
    ("cell stabilising", [
        ("wifi", False, 0, 100, "flat", 0.0), ("cell", True, 250, 2.0, "rising", 0.55), ("link", True, 80, 25.0, "flat", 0.2)]),
    ("cell flaps down again", [
        ("wifi", False, 0, 100, "flat", 0.0), ("cell", False, 0, 100, "falling", 0.1), ("link", True, 80, 18.0, "flat", 0.25)]),
    ("wifi returns weak but rising", [
        ("wifi", True, 150, 3.0, "rising", 0.5), ("cell", False, 0, 100, "flat", 0.1), ("link", True, 80, 18.0, "flat", 0.25)]),
    ("wifi recovering", [
        ("wifi", True, 80, 1.0, "rising", 0.75), ("cell", True, 220, 2.0, "rising", 0.5), ("link", True, 80, 18.0, "flat", 0.25)]),
    ("fully recovered", [
        ("wifi", True, 50, 0.5, "flat", 0.9), ("cell", True, 180, 1.0, "flat", 0.6), ("link", True, 70, 10.0, "flat", 0.35)]),
]

USABLE_LOSS = 20.0


def usable(lane) -> bool:
    _, up, _, loss, _, _ = lane
    return up and loss < USABLE_LOSS


def lane_table(lanes) -> str:
    rows = [
        f"  {lid}: {'UP' if up else 'DOWN'} rtt={rtt}ms loss={loss}% trend={trend} score={score}"
        for lid, up, rtt, loss, trend, score in lanes
    ]
    return "\n".join(rows)


def baseline_decision(lanes) -> str:
    cands = [l for l in lanes if usable(l)]
    if not cands:
        return "queue"
    return max(cands, key=lambda l: l[5])[0]


def ask_model(model: str, prompt: str) -> str:
    req_body = {
        "model": model, "prompt": prompt, "stream": False,
        "options": {"temperature": 0.1, "num_predict": 120},
    }
    if model.startswith(("qwen3", "assistant")):
        req_body["think"] = False
    req = urllib.request.Request(
        "http://localhost:11434/api/generate", data=json.dumps(req_body).encode())
    with urllib.request.urlopen(req, timeout=600) as r:
        text = json.load(r).get("response", "")
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S)


def parse_decision(text: str, lane_ids) -> str | None:
    m = re.search(r"\{.*?\}", text, re.S)
    if m:
        try:
            v = json.loads(m.group(0)).get("send_via", "")
            if v in lane_ids or v == "queue":
                return v
        except json.JSONDecodeError:
            pass
    low = text.lower()
    if "queue" in low:
        return "queue"
    for lid in lane_ids:
        if lid in low:
            return lid
    return None


def run_agent(name: str, decide) -> dict:
    score, delivered, lost, queued_pending, switches = 0, 0, 0, 0, 0
    last_lane, log = None, []
    for i, (desc, lanes) in enumerate(STEPS):
        lane_ids = [l[0] for l in lanes]
        # auto-flush the store-and-forward queue when anything is usable
        if queued_pending and any(usable(l) for l in lanes):
            delivered += queued_pending
            score += queued_pending  # +1 each: arrived late but arrived
            queued_pending = 0
        choice = decide(i, desc, lanes)
        any_usable = any(usable(l) for l in lanes)
        if choice is None:
            choice = "queue"  # unparseable answer degrades to queueing
        if choice == "queue":
            if any_usable:
                score -= 1
                queued_pending += 1
                verdict = "needless-queue"
            else:
                score += 1
                queued_pending += 1
                verdict = "correct-queue"
        else:
            lane = next(l for l in lanes if l[0] == choice)
            if usable(lane):
                score += 2
                delivered += 1
                verdict = "delivered"
                if last_lane and choice != last_lane:
                    switches += 1
                last_lane = choice
            else:
                score -= 2
                lost += 1
                queued_pending += 1  # app retries it from the queue
                verdict = "sent-to-dead-lane"
        log.append(f"  step{i:02d} [{desc}] -> {choice}: {verdict}")
    thrash = max(0, switches - 4)
    score -= thrash
    return {
        "score": score, "delivered": delivered, "lost": lost,
        "switches": switches, "thrash_penalty": thrash, "log": log,
    }


def model_decider(model: str):
    history: list[str] = []
    def decide(i, desc, lanes):
        prompt = (
            "You route messages for a chat app that must stay connected in any "
            "condition. A lane delivers only if UP with loss under 20%.\n"
            f"Step {i} — {desc}. Lanes:\n" + lane_table(lanes) + "\n"
            + ("Recent decisions: " + ", ".join(history[-3:]) + "\n" if history else "")
            + 'Reply ONLY JSON: {"send_via": "wifi"|"cell"|"link"|"queue"}. '
            "Prefer a healthy rising lane; queue only when nothing is usable; "
            "avoid pointless lane switching."
        )
        try:
            choice = parse_decision(ask_model(model, prompt), [l[0] for l in lanes])
        except Exception:  # noqa: BLE001
            choice = None
        history.append(f"step{i}={choice}")
        return choice
    return decide


def main() -> None:
    models = sys.argv[1].split(",") if len(sys.argv) > 1 else ["baseline"]
    results = {}
    for m in models:
        t0 = time.time()
        if m == "baseline":
            r = run_agent(m, lambda i, d, lanes: baseline_decision(lanes))
        else:
            r = run_agent(m, model_decider(m))
        r["wall_s"] = round(time.time() - t0, 1)
        results[m] = r
        print(f"\n===== {m} ({r['wall_s']}s) =====")
        print("\n".join(r.pop("log")))
        print("  " + json.dumps(r))
    print("\n===== GAUNTLET FINAL =====")
    for m, r in sorted(results.items(), key=lambda kv: -kv[1]["score"]):
        print(f"{m:18s} score {r['score']:3d}  delivered {r['delivered']:2d}  "
              f"lost {r['lost']}  switches {r['switches']}")


if __name__ == "__main__":
    main()
