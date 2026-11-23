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
- 法律全文豁免：BearyAccountText.privacy／.terms 两处整篇法律字面量内的新增行不拦——
  法律全文是文档不是界面文案；服务端下发、包内兜底；英文版待隐私政策 v2 审定后再做。
  只按这两个字面量的起止行豁免（legal_text_ranges），不放宽到整个文件或整类文件。

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

# 法律全文豁免：只豁免 BearyAccountText.privacy／.terms 两个整篇法律字面量内的
# 新增行（见 legal_text_ranges，按字面量起止行锚定）。不放宽到整个文件。
LEGAL_TEXT_FILE = "ios/App/App/BearySettingsViewController.swift"
LEGAL_TEXT_LITERALS = ("privacy", "terms")

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


def legal_text_ranges():
    """返回 {文件: [(起始行, 结束行), ...]}：HEAD 版文件里两个法律字面量的行范围。

    按 `static let privacy/terms = \"\"\"` 起止锚定；取不到范围时返回空——
    fail-closed，豁免不生效，guard 照常拦。
    """
    try:
        proc = subprocess.run(
            ["git", "show", f"HEAD:{LEGAL_TEXT_FILE}"],
            capture_output=True, text=True, check=True,
        )
    except subprocess.CalledProcessError:
        return {}
    opener = re.compile(
        r"\s*static let (" + "|".join(LEGAL_TEXT_LITERALS) + r') = """\s*$'
    )
    ranges = []
    lines = proc.stdout.splitlines()
    i = 0
    while i < len(lines):
        if opener.match(lines[i]):
            start = i + 1  # 1-based 行号
            j = i + 1
            while j < len(lines) and lines[j].strip() != '"""':
                j += 1
            if j < len(lines):
                ranges.append((start, j + 1))
            i = j + 1
        else:
            i += 1
    return {LEGAL_TEXT_FILE: ranges} if ranges else {}


def scan_diff(diff_text: str, exempt_ranges=None):
    """扫一段 git diff 文本（-U0），返回 [(文件, 行号, 种类, 字面量, 代码行)]。
    种类为 "中文" 或 "英文文案"。纯函数，便于单测（不跑 git）。"""
    violations = []
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
        for lit, _q in lits:
            if CJK.search(lit):
                hit = ("中文", lit)
                break
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
            exempt = False
            if exempt_ranges:
                for s, e in exempt_ranges.get(cur_file, []):
                    if s <= cur_line <= e:
                        exempt = True
                        break
            if not exempt:
                violations.append((cur_file, cur_line, kind, lit, added.strip()))
        cur_line += 1
    return violations


def check_diff(base: str):
    cmd = ["git", "diff", "-U0", f"{base}...HEAD", "--"] + SWIFT_PATHS
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"取 diff 失败（base={base}）：{proc.stderr.strip()}", file=sys.stderr)
        return None
    return scan_diff(proc.stdout, legal_text_ranges())


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
