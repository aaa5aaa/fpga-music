#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成修正版伴奏 JSON：移调避开同音冲突，压低伴奏力度，重算 delta。"""
import json
from pathlib import Path

BASE = Path(r"D:\musial_v22\musial_v12_bt_timbre_knob\miniprogram\examples")
SONGS = {
    "jingle_bells_full_accomp.json": "铃儿响叮当",
    "ode_to_joy_full_accomp.json": "欢乐颂",
    "twinkle_full_accomp.json": "小星星",
    "two_tigers_full_accomp.json": "两只老虎",
}


def pair_spans(events):
    """按 FIFO 配对同音 note-on/off，返回 [start, end, note, vel]。"""
    t = 0
    active = {}
    spans = []
    for d, n, v in events:
        t += int(d)
        if int(v) > 0:
            spans.append([t, None, int(n), int(v)])
            active.setdefault(int(n), []).append(len(spans) - 1)
        else:
            q = active.get(int(n))
            if q:
                idx = q.pop(0)
                spans[idx][1] = t
    end_time = t + 100
    for s in spans:
        if s[1] is None:
            s[1] = end_time
    return spans


def overlaps(a0, a1, b0, b1):
    return a0 < b1 and b0 < a1


def fix_one(path, title):
    obj = json.loads(path.read_text(encoding="utf-8"))
    spans = pair_spans(obj.get("events", []))
    melody = [s for s in spans if s[3] >= 150]
    accomp = [s for s in spans if s[3] < 150]

    # 主旋律固定；伴奏逐个找不冲突的音高
    fixed = [(s[0], s[1], s[2]) for s in melody]
    assigned = []
    result = []
    skipped = 0
    for s in sorted(accomp, key=lambda x: (x[0], x[2])):
        start, end, note, vel = s
        if end <= start:
            end = start + 50
        target = None
        # 优先原音高，再尝试八度（保持和弦/音级不变，不试五度/四度）
        for shift in (0, 12, -12, 24, -24):
            n = note + shift
            if not (0 <= n < 32):
                continue
            if any(n == mn and overlaps(start, end, ms, me) for ms, me, mn in fixed):
                continue
            if any(n == an and overlaps(start, end, as_, ae) for as_, ae, an in assigned):
                continue
            target = n
            break
        if target is None:
            skipped += 1
            continue
        assigned.append((start, end, target))
        # 伴奏力度压到 24..40
        v = max(24, min(40, int(round(vel * 0.55))))
        result.append((start, target, v, 1))
        result.append((end, target, 0, 0))

    # 主旋律事件
    for start, end, note in fixed:
        result.append((start, note, 200, 1))
        result.append((end, note, 0, 0))

    # 同一时刻先 off 再 on
    result.sort(key=lambda e: (e[0], e[3]))
    out = []
    prev = 0
    for t, n, v, _ in result:
        d = max(0, min(65535, t - prev))
        out.append([d, n, v])
        prev = t

    # 校验
    active = set()
    bad_on = bad_off = 0
    for d, n, v in out:
        if v:
            if n in active:
                bad_on += 1
            active.add(n)
        else:
            if n in active:
                active.discard(n)
            else:
                bad_off += 1

    new_obj = {"name": title, "events": out}
    dest = BASE / (title + ".json")
    dest.write_text(json.dumps(new_obj, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")
    print("%s: spans=%d melody=%d accomp=%d skipped=%d events=%d overlap=%d orphan=%d" %
          (title, len(spans), len(melody), len(accomp), skipped,
           len(out), bad_on, bad_off))
    return dest


def main():
    # 先全部生成，成功后再删旧文件
    outputs = []
    for src, title in SONGS.items():
        p = BASE / src
        if p.exists():
            outputs.append(fix_one(p, title))
        else:
            print("missing:", p)

    # 只清理旧的 *_full_accomp.json 源文件，不删其他曲谱
    for p in BASE.iterdir():
        if p.is_file() and p.suffix.lower() == ".json" and \
                p.name.endswith("_full_accomp.json"):
            p.unlink()
            print("removed source:", p.name)


if __name__ == "__main__":
    main()
