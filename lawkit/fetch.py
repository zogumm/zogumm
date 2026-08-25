#!/usr/bin/env python3
"""법제처 Open API로 법령 본문 + 별표를 통째로 받아두고, 개정을 감지한다.

왜 매번 조회하지 않고 받아두는가:
  - 별표 본문은 API가 텍스트로 주지 않는다. HWP/PDF 파일 링크로 온다.
    매 검토마다 한글 파일을 파싱하는 건 느리고 잘 깨진다.
  - 법규검토는 근거를 인용하는 작업이라, 검증되지 않은 자동 파싱 결과를
    그대로 쓰면 안 된다. 사람이 한 번 검수한 룰이 훨씬 안전하다.
  - 별표 개정은 연 1~2회 수준이다. 실시간일 이유가 없다.

그래서 API는 본문 조회용이 아니라 "변경 감지용"으로 쓴다.
  fetch  : 본문 + 별표 내려받고 manifest 기록
  check  : manifest와 현재 시행일자를 비교해 개정된 법령만 보고

사용:
  python3 fetch.py fetch --oc <아이디>       # 전체 수집
  python3 fetch.py check --oc <아이디>       # 개정분만 확인

--oc 는 국가법령정보센터 가입 이메일의 @ 앞부분이다.
(hong@gmail.com 이면 --oc hong)
"""

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request

from laws import LAWS

BASE = "https://www.law.go.kr"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
MANIFEST = os.path.join(OUT, "manifest.json")
UA = "Mozilla/5.0 (lawkit)"


def get(url, binary=False, retries=3):
    """법제처 API는 간헐적으로 끊긴다. 몇 번 다시 시도한다."""
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
            return raw if binary else raw.decode("utf-8", "replace")
        except Exception as e:
            if attempt == retries - 1:
                raise
            time.sleep(2 ** attempt)


def dig(obj, key):
    """법제처 JSON은 응답마다 중첩 깊이가 달라서 키로 훑어 찾는다."""
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for v in obj.values():
            found = dig(v, key)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = dig(v, key)
            if found is not None:
                return found
    return None


def as_list(x):
    if x is None:
        return []
    return x if isinstance(x, list) else [x]


def 제목(row):
    """법령은 '법령명한글', 자치법규는 '자치법규명' 으로 필드명이 다르다."""
    return (row.get("법령명한글") or row.get("자치법규명") or "").strip()


def parse_search(data, name, target):
    """
    검색 응답에서 메타 1건을 뽑는다. 네트워크와 분리된 순수 함수라 테스트할 수 있다.

    법제처 응답은 결과가 1건이면 dict, 여러 건이면 list 로 온다.
    중첩 깊이도 target 마다 달라서 dig 로 훑는다.
    """
    rows = [r for r in as_list(dig(data, "law") or dig(data, "ordin")) if isinstance(r, dict)]

    # 결과 0건이면 래퍼({"totalCnt": "0"})만 남는다. 레코드처럼 생긴 것만 남긴다.
    rows = [r for r in rows
            if 제목(r) or r.get("법령일련번호") or r.get("자치법규일련번호")]

    if not rows:
        return None, "검색 결과 없음 (법령명 확인 필요)"

    # "건축법" 으로 검색하면 시행령·시행규칙이 같이 온다. 정확히 일치하는 걸 우선한다.
    exact = [r for r in rows if 제목(r) == name]
    row = exact[0] if exact else rows[0]

    meta = {
        "요청명": name,
        "법령명": 제목(row),
        "target": target,
        "MST": row.get("법령일련번호") or row.get("자치법규일련번호"),
        "ID": row.get("법령ID") or row.get("자치법규ID"),
        "공포일자": row.get("공포일자"),
        "시행일자": row.get("시행일자"),
    }
    if not meta["MST"]:
        return None, f"일련번호(MST) 없음 — 응답 구조 확인 필요: {list(row)[:6]}"
    return meta, None


def parse_byeolpyo(parsed):
    """본문 응답에서 별표 목록을 뽑는다."""
    return [b for b in as_list(dig(parsed, "별표단위")) if isinstance(b, dict)]


def search(oc, name, target):
    """법령명으로 검색해 가장 잘 맞는 1건의 메타를 돌려준다."""
    q = urllib.parse.quote(name)
    url = f"{BASE}/DRF/lawSearch.do?OC={oc}&target={target}&type=JSON&display=20&query={q}"
    try:
        data = json.loads(get(url))
    except Exception as e:
        return None, f"검색 실패: {e}"
    return parse_search(data, name, target)


def fetch_body(oc, meta):
    """본문 JSON을 받아 저장하고, 별표 목록을 돌려준다."""
    url = (f"{BASE}/DRF/lawService.do?OC={oc}&target={meta['target']}"
           f"&type=JSON&MST={meta['MST']}")
    body = get(url)

    slug = meta["법령명"].replace("/", "_").replace(" ", "_")
    d = os.path.join(OUT, slug)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "본문.json"), "w", encoding="utf-8") as f:
        f.write(body)

    try:
        parsed = json.loads(body)
    except Exception:
        return d, []

    return d, parse_byeolpyo(parsed)


def plan_attachment(b):
    """
    별표 1건에서 (라벨, 다운로드 URL, 저장 파일명) 을 만든다.
    링크가 없으면 url 이 None 이다. 네트워크를 타지 않으므로 테스트할 수 있다.
    """
    num = (b.get("별표번호") or "").strip()
    title = (b.get("별표제목") or "").strip()
    link = (b.get("별표서식파일링크") or b.get("별표서식PDF파일링크") or "").strip()

    label = f"별표{num} {title}".strip()
    if not link:
        return label, None, None

    url = link if link.startswith("http") else BASE + link
    ext = ".pdf" if "PDF" in link.upper() else ".hwp"
    safe = "".join(c for c in label if c not in '\\/:*?"<>|').strip()[:80]
    return label, url, safe + ext


def fetch_attachments(d, byeolpyo):
    """별표 파일(HWP/PDF)을 내려받는다. 링크가 없으면 건너뛴다."""
    saved, skipped = [], []
    adir = os.path.join(d, "별표")

    for b in byeolpyo:
        label, url, fname = plan_attachment(b)
        if not url:
            skipped.append(f"{label} (파일 링크 없음)")
            continue

        try:
            blob = get(url, binary=True)
        except Exception as e:
            skipped.append(f"{label} (다운로드 실패: {e})")
            continue

        os.makedirs(adir, exist_ok=True)
        with open(os.path.join(adir, fname), "wb") as f:
            f.write(blob)
        saved.append(label)

    return saved, skipped


def load_manifest():
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_manifest(m):
    os.makedirs(OUT, exist_ok=True)
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False, indent=2)


def cmd_fetch(args):
    manifest = load_manifest()
    ok = fail = 0

    for name, target in LAWS:
        meta, err = search(args.oc, name, target)
        if err:
            print(f"  ✗ {name} — {err}")
            fail += 1
            continue

        try:
            d, byeolpyo = fetch_body(args.oc, meta)
            saved, skipped = fetch_attachments(d, byeolpyo)
        except Exception as e:
            print(f"  ✗ {name} — 본문 수집 실패: {e}")
            fail += 1
            continue

        meta["별표수"] = len(byeolpyo)
        meta["받은별표"] = saved
        meta["못받은별표"] = skipped
        manifest[name] = meta
        ok += 1

        print(f"  ✓ {meta['법령명']}  시행 {meta['시행일자']}  별표 {len(saved)}/{len(byeolpyo)}")
        for s in skipped:
            print(f"      ! {s}")

    save_manifest(manifest)
    print(f"\n수집 {ok}건 / 실패 {fail}건 → {OUT}")
    if fail:
        print("실패 건은 laws.py 의 법령명을 국가법령정보센터 표기와 맞춰주세요.")


def load_rules():
    """rules/*.json 을 읽는다. 어떤 룰이 어느 법령을 옮긴 것인지 대조하기 위해서."""
    d = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rules")
    out = []
    if not os.path.isdir(d):
        return out
    for f in sorted(os.listdir(d)):
        if not f.endswith(".json"):
            continue
        with open(os.path.join(d, f), encoding="utf-8") as fh:
            out.append(json.load(fh))
    return out


def stale_rules(manifest):
    """
    룰이 최신 법령 기준인지 본다.

    계산은 항상 최신 법으로 한다. 그래서 확인해야 할 건 딱 하나 —
    이 룰이 옮겨 적은 시점의 법령이 아직도 최신인가.
    """
    rows = []
    for rule in load_rules():
        법령 = rule.get("법령")
        meta = manifest.get(법령)
        기준 = rule.get("기준시행일")
        현재 = meta.get("시행일자") if meta else None

        if 기준 is None:
            rows.append((rule.get("id"), 법령, "미기록", 현재 or "?"))
        elif 현재 and 기준 != 현재:
            rows.append((rule.get("id"), 법령, 기준, 현재))
    return rows


def cmd_check(args):
    """저장된 시행일자와 현재 시행일자를 비교한다. 첫 화면 알림의 원천."""
    manifest = load_manifest()
    if not manifest:
        print("manifest 가 없습니다. 먼저 fetch 를 실행하세요.")
        return 1

    changed = []
    for name, target in LAWS:
        old = manifest.get(name)
        if not old:
            changed.append((name, "미수집", "-"))
            continue
        meta, err = search(args.oc, name, target)
        if err:
            print(f"  ? {name} — {err}")
            continue
        if meta["시행일자"] != old.get("시행일자"):
            changed.append((name, old.get("시행일자"), meta["시행일자"]))

    if changed:
        print(f"\n⚠ 개정 감지 {len(changed)}건\n")
        for name, before, after in changed:
            print(f"  {name}")
            print(f"    시행일 {before} → {after}")
        print("\n→ fetch 를 다시 돌린 뒤, 해당 법령을 쓰는 룰을 검수하세요.")
    else:
        print("개정 없음. 모든 법령이 최신입니다.")

    # 계산은 항상 최신 법으로 한다. 그러니 확인할 건 룰이 아직 최신인지 하나뿐이다.
    stale = stale_rules(manifest)
    if stale:
        print(f"\n⚠ 최신 확인 안 되는 룰 {len(stale)}건\n")
        for rid, 법령, 기준, 현재 in stale:
            print(f"  {rid}  ({법령})")
            print(f"    룰 기준 {기준}  /  현재 시행 {현재}")
        print("\n→ 룰을 다시 대조하고 기준시행일을 갱신하세요.")
    else:
        print("모든 룰이 최신 법령 기준입니다.")

    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="본문 + 별표 전체 수집")
    f.add_argument("--oc", required=True, help="국가법령정보센터 가입 이메일의 @ 앞부분")
    f.set_defaults(func=cmd_fetch)

    c = sub.add_parser("check", help="개정된 법령만 확인")
    c.add_argument("--oc", required=True)
    c.set_defaults(func=cmd_check)

    args = p.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
