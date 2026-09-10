#!/usr/bin/env python3
"""远程规则集漂移检查 + 四端自定义规则一致性检查。

用法：python3 scripts/check-rulesets.py   （任一项不通过退出码为 1）

检查内容：
1. blackmatrix7 规则集：按「客户端/规则集名」汇总本仓库引用的所有文件的实际条数，
   与文件头 `# TOTAL:` 比较。2026-09 上游把 DOMAIN-SUFFIX 拆到 *_Domain 文件而头部统计
   没更新，只引用 .list 时实际条数远小于声明，域名规则静默失效。这里把它变成可见的失败。
2. 其他远程规则集（MetaCubeX geosite、本仓库 raw）：能拉取且非空。
3. 四端自定义规则（Ai / Proxy / Direct）：surge list、ss list、clash yaml、singbox json 条目数一致。
"""
import json, os, re, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOLERANCE = 0.95          # 实际条数 / 声明条数 低于此值判定为漂移
UA = "xx_script-check-rulesets/1.0"
BM7 = re.compile(r"ios_rule_script(?:/master|@master)/rule/([^/]+)/([^/]+)/([^/?#]+)")


def fetch(url, tries=3):
    last = None
    for _ in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            last = e
    raise RuntimeError(f"拉取失败 {url}: {last}")


def count_rules(text, name):
    """yaml 数 payload 的 '- ' 行；list 数非注释非空行"""
    if name.endswith((".yaml", ".yml")):
        return sum(1 for l in text.splitlines() if re.match(r"^\s*-\s+\S", l))
    return sum(1 for l in text.splitlines()
               if l.strip() and not l.lstrip().startswith(("#", ";", "//")))


def declared_total(text):
    m = re.search(r"^#\s*TOTAL:\s*(\d+)", text, re.M)
    return int(m.group(1)) if m else None


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def collect_urls():
    urls = []
    for m in re.finditer(r"^(?:RULE-SET|DOMAIN-SET),(https?://[^,\s]+),", read("ss/shadowrocket.conf"), re.M):
        urls.append(("shadowrocket.conf", m.group(1)))
    for m in re.finditer(r'url:\s*"(https?://[^"]+)"', read("clash/proxy-transformer.js")):
        urls.append(("proxy-transformer.js", m.group(1)))
    return urls


def check_remote():
    ok = True
    groups, others = {}, []
    for src, url in collect_urls():
        try:
            text = fetch(url)
        except RuntimeError as e:
            print(f"❌ {e}"); ok = False; continue
        n = count_rules(text, url)
        m = BM7.search(url)
        if m:
            client, name, fname = m.groups()
            g = groups.setdefault((client, name), {"files": [], "declared": None, "src": set()})
            g["files"].append((fname, n)); g["src"].add(src)
            d = declared_total(text)
            if d:
                g["declared"] = max(g["declared"] or 0, d)
        else:
            others.append((src, url, n))

    print("== blackmatrix7 规则集：本仓库引用文件的实际条数 vs 头部声明 TOTAL ==")
    for (client, name), g in sorted(groups.items()):
        actual = sum(n for _, n in g["files"]); d = g["declared"]
        files = " + ".join(f"{f}({n})" for f, n in g["files"])
        if d is None:
            status = "⚠️ 无 TOTAL 头"
        elif actual >= d * TOLERANCE:
            status = "✅"
        else:
            status = "❌ 漂移（上游可能又拆了文件，需配对引用）"; ok = False
        print(f"{status} {client}/{name}: 声明 {d} 实际 {actual}  [{files}]  ← {', '.join(sorted(g['src']))}")

    print("\n== 其他远程规则集（能拉取且非空）==")
    for src, url, n in others:
        good = n > 0; ok = ok and good
        print(f"{'✅' if good else '❌ 空文件'} {n:>6} 条  {url}  ← {src}")
    return ok


def check_four_ends():
    print("\n== 四端自定义规则条目数一致性 ==")
    ok = True
    for name, sb in (("Ai", "ai-custom"), ("Proxy", "proxy-custom"), ("Direct", "direct-custom")):
        counts = {}
        for rel in (f"surge/rules/{name}.list", f"ss/rules/{name}.list", f"clash/rules/{name}.yaml"):
            counts[rel] = count_rules(read(rel), rel)
        rel = f"singbox/rules/{sb}.json"
        counts[rel] = sum(len(v) for r in json.loads(read(rel))["rules"] for v in r.values())
        same = len(set(counts.values())) == 1
        ok = ok and same
        print(f"{'✅' if same else '❌ 不一致'} {name}: " + ", ".join(f"{k.split('/')[0]}={v}" for k, v in counts.items()))
    return ok


if __name__ == "__main__":
    good = check_remote() & check_four_ends()
    print("\n结果：" + ("全部通过" if good else "有问题，见上方 ❌"))
    sys.exit(0 if good else 1)
