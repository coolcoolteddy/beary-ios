#!/usr/bin/env python3
"""多语言防回潮检查：只查本 PR diff 新增行里的硬编码文案（中文＋英文）。

设计（防炸队里约 270 支排队 PR）：
- 只看 `git diff <base>...HEAD` 的新增行（+ 行），不动存量；
- 只扫 Swift 源码（ios/App/App/*.swift、ios/App/BearyCoreTests/*.swift）；
- 已包进 NSLocalizedString(...) / String(localized: ...) 的 key 参数不算
  （key 是语义 key，不含中文）；
- 注释里的中文不算；DateFormatter 的 dateFormat（如 "M月d日"）不算，
  那是格式串不是文案；
- 白名单文件：ios/App/BearyCoreTests/BearyI18nCatalogTests.swift——
  它以中文原文作期望值断言，中文是测试数据本身。
- 挪位置豁免：新增行里的中文串若在同一 PR 的删除行里原样出现过
  （整段字面量逐字相同），只算挪了位置，不标红；只有删除行里没有的
  新文案才进 catalog。

两项检查（同一行只报一处，中文优先）：
1. 中文：新增行里 NSLocalizedString key 参数之外的中文字符串字面量即失败。
2. 英文文案：新增行里写进界面文案位置的英文 literal 即失败——只认
   UI 文案赋值处（.text / .title / setTitle( / .placeholder /
   accessibilityLabel / accessibilityHint / UIAlertController title: /
   message:），其他位置的英文 literal（如图片名、UserDefaults key、
   埋点名）不拦。品牌词 beary／Plus 走脚本内显式小 allowlist（字面量
   本身就是品牌词时放行，含品牌词的文案照样拦）。

用法：python3 scripts/check-i18n-hardcoded.py [--base <ref>]
默认 base 为 origin/main；CI 里传 pull_request.base.sha。
退出码：0 通过；1 发现新增硬编码文案；2 用法/取 diff 失败。
"""
import argparse
import fnmatch
import re
import subprocess
import sys

CJK = re.compile(r"[\u4e00-\u9fff]")
ASCII_LETTER = re.compile(r"[A-Za-z]")
# 注意：只扫 *.swift，不扫同目录下的 .xcstrings（catalog 里是翻译数据，
# 不能把它当新增硬编码文案查——此前写目录曾误扫 catalog，已改 glob）。
SWIFT_PATHS = ["ios/App/App/*.swift", "ios/App/BearyCoreTests/*.swift"]
ALLOWLIST_FILES = {
    "ios/App/BearyCoreTests/BearyI18nCatalogTests.swift",
}

# 品牌词 allowlist：字面量本身（去空白、不分大小写）就是品牌词时放行。
# 含品牌词的文案（如 "beary is locked"）不是品牌词本身，照样拦。
BRAND_ALLOWLIST = {"beary", "plus"}

# UI 文案赋值处：正则须匹配到字面量的左引号为止（含引号），调用方用行尾锚定，
# 只认紧贴在赋值处的那一个字面量（如 `.text = cond ? "a" : "b"` 的三元分支不认，
# 已知局限）。只认 UIKit 文案赋值处。
UI_COPY_RES = [
    re.compile(r"\.\s*text\s*=\s*\"$"),
    re.compile(r"\.\s*title\s*=\s*\"$"),
    re.compile(r"setTitle\(\s*\"$"),
    re.compile(r"\.\s*placeholder\s*=\s*\"$"),
    re.compile(r"accessibilityLabel\s*=\s*\"$"),
    re.compile(r"accessibilityHint\s*=\s*\"$"),
    re.compile(r"UIAlertController\(\s*title\s*:\s*\"$"),
    re.compile(r"\bmessage\s*:\s*\"$"),
]

# NSLocalizedString("key", ...) / String(localized: "key") ——把 key 串删掉再扫残留。
LOCALIZED_RE = re.compile(r"(?:NSLocalizedString|String\(localized:)\s*\(\s*\"(?:\\.|[^\"\\])*\"")


def strip_line_comment(line: str) -> str:
    """删 // 注释（字符串内的 // 不动：按引号状态走）。"""
    out = []
    i, n = 0, len(line)
    in_str = False
    while i < n:
        ch = line[i]
        if in_str:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(line[i + 1])
                i += 2
                continue
            if ch == '"':
                in_str = False
            i += 1
            continue
        if ch == '"':
            in_str = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and line[i + 1] == "/":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def string_literals_with_pos(code: str):
    """返回 (字面量内容, 左引号下标) 列表。"""
    out = []
    for m in re.finditer(r'"(?:\\.|[^"\\])*"', code):
        out.append((m.group(0)[1:-1], m.start()))
    return out


def is_swift_path(path: str) -> bool:
    return any(fnmatch.fnmatch(path, pat) for pat in SWIFT_PATHS)


def moved_literals(diff_text: str):
    """同一 PR 删除行里的字符串字面量集合（挪位置豁免用）。

    只收与新增行同口径的行：Swift 源码路径、非白名单文件、去 // 注释后
    抽出的字面量原文。比对时整段字面量逐字相同才算挪位置（含插值段原文，
    如 "\\(stateText) · 上次同步 ..." 与 "\\(state.displayText) · 上次同步 ..."
    是两个不同的串，后者不豁免前者）。
    """
    removed = set()
    cur_file = None
    for raw in diff_text.splitlines():
        if raw.startswith("+++ b/"):
            cur_file = raw[len("+++ b/"):]
            continue
        if not raw.startswith("-") or raw.startswith("---"):
            continue
        if cur_file is None or not is_swift_path(cur_file) or cur_file in ALLOWLIST_FILES:
            continue
        for lit, _q in string_literals_with_pos(strip_line_comment(raw[1:])):
            removed.add(lit)
    return removed


def scan_diff(diff_text: str):
    """扫一段 git diff 文本（-U0），返回 [(文件, 行号, 种类, 字面量, 代码行)]。
    种类为 "中文" 或 "英文文案"。纯函数，便于单测（不跑 git）。"""
    violations = []
    moved = moved_literals(diff_text)
    cur_file = None
    cur_line = 0
    for raw in diff_text.splitlines():
        if raw.startswith("+++ b/"):
            cur_file = raw[len("+++ b/"):]
            continue
        if raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            cur_line = int(m.group(1)) if m else 0
            continue
        if not raw.startswith("+") or raw.startswith("+++"):
            continue
        if cur_file is None or not is_swift_path(cur_file) or cur_file in ALLOWLIST_FILES:
            cur_line += 1
            continue
        added = raw[1:]
        if "dateFormat" in added:
            cur_line += 1
            continue
        code = strip_line_comment(added)
        # 把 NSLocalizedString("key", ...) / String(localized: "key") 的 key 串整段删掉再扫
        code = LOCALIZED_RE.sub(
            lambda m: "NSLocalizedString(" if m.group(0).startswith("NSLocalizedString") else "String(localized:(",
            code,
        )
        lits = string_literals_with_pos(code)
        hit = None
        cjk_lits = [lit for lit, _q in lits if CJK.search(lit)]
        for lit in cjk_lits:
            if lit not in moved:
                hit = ("中文", lit)
                break
        if hit is None and cjk_lits:
            # 行内中文串全部在删除行里原样出现过：纯挪位置，豁免整行。
            # 英文检查也不跑——该行此前报中文时英文检查本就到不了。
            cur_line += 1
            continue
        if hit is None:
            for lit, q in lits:
                if not ASCII_LETTER.search(lit):
                    continue
                if lit.strip().casefold() in BRAND_ALLOWLIST:
                    continue
                prefix = code[: q + 1]
                if any(rx.search(prefix) for rx in UI_COPY_RES):
                    hit = ("英文文案", lit)
                    break
        if hit is not None:
            kind, lit = hit
            violations.append((cur_file, cur_line, kind, lit, added.strip()))
        cur_line += 1
    return violations


def check_diff(base: str):
    cmd = ["git", "diff", "-U0", f"{base}...HEAD", "--"] + SWIFT_PATHS
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"取 diff 失败（base={base}）：{proc.stderr.strip()}", file=sys.stderr)
        return None
    return scan_diff(proc.stdout)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main")
    args = ap.parse_args()
    violations = check_diff(args.base)
    if violations is None:
        return 2
    if not violations:
        print("i18n 检查通过：新增行里没有硬编码中文文案，也没有写进界面文案位置的硬编码英文。")
        return 0
    print(f"i18n 检查失败：{len(violations)} 处新增硬编码文案，请改走 NSLocalizedString：")
    for path, line, kind, lit, code in violations:
        print(f"  {path}:{line} [{kind}] {lit!r}")
        print(f"    {code}")
    print("说明：中文原文进 ios/App/App/Localizable.xcstrings 作 source value，代码用 NSLocalizedString(语义 key)；")
    print("      插值改 String(format: NSLocalizedString(\"...%@...\"), 变量)；英文 UI 文案同样进 catalog，")
    print("      品牌词 beary／Plus 本身除外；见 docs/i18n-plan.md。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
