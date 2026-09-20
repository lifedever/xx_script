#!/usr/bin/env python3
"""从 FlClash 的订阅列表生成混合配置的 proxy-providers。

背景：FlClash 的「配置」是互斥的整份配置（同时只能激活一个），而 mihomo 的
proxy-providers 是可并存的节点来源。想同时用多家机场，只能维护一份带
proxy-providers 的本地配置 —— 这个脚本就是把前者同步成后者，省去手抄订阅链接。

覆写脚本 proxy-transformer.js 不需要改：它运行时枚举 proxy-providers 的 key
生成「📦 <机场>」组，这里多一家，Clash 里就自动多一个组。

用法：
    python3 scripts/sync-flclash-providers.py            # dry-run，只打印
    python3 scripts/sync-flclash-providers.py --apply    # 写入 FlClash 配置

写入后需要在 FlClash 里切走再切回该配置才会重新加载。

注意：生成的文件含真实订阅链接，只落在本机，不要提交进本仓库。
"""

import argparse
import pathlib
import re
import sqlite3
import sys
import time

FLCLASH_DIR = pathlib.Path.home() / "Library/Application Support/com.follow.clash"
DB = FLCLASH_DIR / "database.sqlite"

# 目标配置的 label（url 为空的本地文件配置）。脚本会覆写它，并跳过它自身。
TARGET_LABEL = "混合配置"

# 不想并进来的订阅，按 label 填
EXCLUDE: set[str] = set()

# 节点名前缀别名；没填的按 label 第一个空格/连字符前的部分取
PREFIX_ALIAS = {"DMIT - EB": "DMIT"}

# provider 重新拉取订阅的间隔（秒）。24 小时 —— 机场节点变动不频繁，
# 要立刻更新用「代理页 ⋮ → 外部资源 → 同步」，不靠缩短这个值
INTERVAL = 86400

HEADER = """\
# FlClash 混合配置：同时启用多家机场（由 scripts/sync-flclash-providers.py 生成）
#
# ⚠️ 含真实订阅链接，只存在于本机，不要放进 xx_script 仓库（公开仓库）。
#    仓库里的模板是 clash/local-providers.example.yaml。
#
# 顶层 key 就是机场组的显示名：写 SoCloud → 覆写脚本生成「📦 SoCloud」组。
# additional-prefix 给该机场所有节点名加前缀，多机场混在一个组里时才分得清来源。

mode: rule

proxy-providers:
"""

BLOCK = """\
  "{name}":
    type: http
    url: "{url}"
    path: ./providers/{slug}.yaml
    override:
      additional-prefix: "[{prefix}] "
    interval: {interval}
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
"""


def slugify(label: str) -> str:
    s = re.sub(r"[^\w一-鿿]+", "-", label.lower()).strip("-")
    return s or "provider"


def prefix_for(label: str) -> str:
    if label in PREFIX_ALIAS:
        return PREFIX_ALIAS[label]
    return re.split(r"[\s\-]+", label.strip())[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="写入配置文件（默认只打印）")
    args = ap.parse_args()

    if not DB.exists():
        print(f"找不到 FlClash 数据库：{DB}", file=sys.stderr)
        return 1

    db = sqlite3.connect(DB)
    rows = db.execute(
        "SELECT id, label, url FROM profiles WHERE url != '' ORDER BY \"order\", id"
    ).fetchall()
    target = db.execute(
        "SELECT id FROM profiles WHERE label = ?", (TARGET_LABEL,)
    ).fetchone()

    providers = [r for r in rows if r[1] not in EXCLUDE and r[1] != TARGET_LABEL]
    if not providers:
        print("没有可用的订阅（profiles 表里 url 全为空）", file=sys.stderr)
        return 1

    body = HEADER + "\n".join(
        BLOCK.format(
            name=label,
            url=url,
            slug=slugify(label),
            prefix=prefix_for(label),
            interval=INTERVAL,
        )
        for _, label, url in providers
    )

    print(f"将并入 {len(providers)} 家机场：")
    for _, label, _url in providers:
        print(f"  📦 {label}    节点名前缀 [{prefix_for(label)}]")

    if not args.apply:
        print("\n(dry-run，未写入。确认无误后加 --apply)")
        return 0

    if not target:
        print(f"\n找不到名为「{TARGET_LABEL}」的配置，请先在 FlClash 里导入一份", file=sys.stderr)
        return 1

    dest = FLCLASH_DIR / "profiles" / f"{target[0]}.yaml"
    # 先备份再覆盖：这个文件可能被手工编辑过（FlClash 的「编辑」入口），
    # 直接覆盖会悄悄吃掉改动
    if dest.exists():
        stamp = time.strftime("%Y%m%d-%H%M%S")
        bak = dest.with_suffix(f".yaml.bak-{stamp}")
        bak.write_text(dest.read_text())
        print(f"\n原文件已备份到 {bak.name}")
    dest.write_text(body)
    backup = pathlib.Path.home() / "Downloads/flclash-providers.yaml"
    backup.write_text(body)
    print(f"已写入 {dest}")
    print(f"备份   {backup}")
    print("去 FlClash 切走再切回「混合配置」重新加载。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
