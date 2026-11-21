#!/usr/bin/env python3
"""多语言防回潮检查：只查本 PR diff 新增行里的硬编码中文文案。

设计（防炸队里约 270 支排队 PR）：
- 只看 `git diff <base>...HEAD` 的新增行（+ 行），不动存量；
- 只扫 Swift 源码（ios/App/App/*.swift、ios/App/BearyCoreTests/*.swift）；
- 已包进 NSLocalizedString(...) / String(localized: ...) 的中文不算；
- 注释里的中文不算；DateFormatter 的 dateFormat（如 "M月d日"）不算，
  那是格式串不是文案；
- 白名单文件：ios/App/BearyCoreTests/BearyI18nCatalogTests.swift——
  它以中文 key 做 catalog 断言，中文是测试数据本身。

用法：python3 scripts/check-i18n-hardcoded.py [--base <ref>]
默认 base 为 origin/main；CI 里传 pull_request.base.sha。
退出码：0 通过；1 发现新增硬编码中文；2 用法/取 diff 失败。
"""
import argparse
import re
import subprocess
import sys

CJK = re.compile(r"[\u4e00-\u9fff]")
# 注意：只扫 *.swift，不扫同目录下的 .xcstrings（catalog 本身就是中文 key，
# 不能把它当新增硬编码文案查——此前写目录曾误扫 catalog，已改 glob）。
SWIFT_PATHS = ["ios/App/App/*.swift", "ios/App/BearyCoreTests/*.swift"]
ALLOWLIST_FILES = {
    "ios/App/BearyCoreTests/BearyI18nCatalogTests.swift",
}

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


def string_literals(line: str):
    """返回行内所有 "..." 字面量内容（不含引号）。"""
    lits = []
    i, n = 0, len(line)
    while i < n:
        if line[i] == '"':
            j = i + 1
            buf = []
            while j < n:
                if line[j] == "\\" and j + 1 < n:
                    buf.append(line[j : j + 2])
                    j += 2
                    continue
                if line[j] == '"':
                    break
                buf.append(line[j])
                j += 1
            lits.append("".join(buf))
            i = j + 1
            continue
        i += 1
    return lits


def check_diff(base: str):
    cmd = ["git", "diff", "-U0", f"{base}...HEAD", "--"] + SWIFT_PATHS
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"取 diff 失败（base={base}）：{proc.stderr.strip()}", file=sys.stderr)
        return None
    violations = []
    cur_file = None
    cur_line = 0
    for raw in proc.stdout.splitlines():
        if raw.startswith("+++ b/"):
            cur_file = raw[len("+++ b/") :]
            continue
        if raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            cur_line = int(m.group(1)) if m else 0
            continue
        if not raw.startswith("+") or raw.startswith("+++"):
            continue
        if cur_file is None or cur_file in ALLOWLIST_FILES:
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
        for lit in string_literals(code):
            if CJK.search(lit):
                violations.append((cur_file, cur_line, lit, added.strip()))
                break
        cur_line += 1
    return violations


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main")
    args = ap.parse_args()
    violations = check_diff(args.base)
    if violations is None:
        return 2
    if not violations:
        print("i18n 检查通过：新增行里没有硬编码中文文案。")
        return 0
    print(f"i18n 检查失败：{len(violations)} 处新增硬编码中文，请改走 NSLocalizedString：")
    for path, line, lit, code in violations:
        print(f"  {path}:{line} {lit!r}")
        print(f"    {code}")
    print("说明：中文原文进 ios/App/App/Localizable.xcstrings，代码用 NSLocalizedString(中文原文)；")
    print("      插值改 String(format: NSLocalizedString(\"...%@...\"), 变量)；见 docs/i18n-plan.md。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
