#!/usr/bin/env bash
# beary-lint.sh — 样式 token 增量 lint：只拦本 PR diff 新增行里的裸值，不扫存量。
#
# 五类（ERROR，任一命中即 exit 1）：
#   font     裸字号：UIFont.systemFont/boldSystemFont/...(ofSize: <数字>)、
#            UIFont(name:..., size: <数字>)。正路：BearyDynamicType 的语义入口
#            （diaryBodyFont/cardTitleFont/secondaryFont/captionFont/...、
#            scaledFont(for:)/cappedFont(for:)）。
#   spacing  裸间距：spacing:/.spacing/UIEdgeInsets(/NSDirectionalEdgeInsets(/
#            contentInset/layoutMargins/sectionInset/separatorInset/
#            minimumLineSpacing/minimumInteritemSpacing 位置上的非零数字。
#            正路：BearySpace（xs 4/sm 8/md 12/lg 16/xl 20/xxl 24/xxxl 32）。
#   corner   裸圆角：cornerRadius = <数字>（layer.cornerRadius 同）。正路：
#            BearyCorners.single（12）。放行：0、1、2（微元素小角，规范 §1 例外）、
#            8（引用缩略图）、20（底 sheet 顶圆角／居中卡片）、999（全圆）；半高药丸
#            写 height/2 表达式，不写字面量。
#   duration 裸时长：withDuration: <数字>、animate/Animator 行的 duration: <数字>。
#            正路：BearyMotion（micro 0.18/normal 0.26/screen 0.38）。放行：0、
#            0.6（定位高亮背景色渐变，规范 §6 例外）。
#   day      裸日界：86400 / 86_400。日界算术走 Calendar（startOfDay、
#            date(byAdding: .day)）或 BearyBeijingDay（北京时间日键）。
#            不拦 24 * 3600：存量里它是缓存 TTL（BearyNativeCommon.swift:837
#            diskCacheMaxAge），不是日界算术，拦了是误报。
#
# 只扫 ios/App/App/*.swift 与 ios/App/BearyCoreTests/*.swift 的新增行
# （git diff -U0 <base>...HEAD）。例外文件：BearyDynamicType.swift（字号 token
# 定义本身）、BearyBeijingDay.swift（日界 86400 的唯一合法出处）。
# 行尾加 `// beary-lint: allow` 可单行放行。同一行只报一处。
#
# 用法：
#   bash tools/beary-lint.sh [--base <ref>] [repo-root]   # 增量，默认 base origin/main
#   bash tools/beary-lint.sh --full [repo-root]           # 存量计量，只打印计数，恒 exit 0
#   bash tools/beary-lint.sh --diff-file <file> [repo-root]  # 读现成 diff（测试用）
# 退出码：0 通过；1 发现新增违规；2 用法/取 diff 失败。
#
# 已知局限（有意收窄，宁漏勿炸）：
# - 只认字面量数字，不认变量（如 ofSize: size 不拦）。
# - 间距不拦裸 `constant:`（宽/高约束与间距约束在该位置无法用正则区分）。
# - `/* */` 块注释不剥离，只剥 `//` 行注释；字符串里的数字可能被当作字面量。
# - cornerRadius 半高例外若写成字面量（如 42）会被拦，须写 height/2 或加 allow。
set -u

BASE="origin/main"
MODE="diff"
DIFF_FILE=""
ROOT="."

usage() {
    echo "用法：bash tools/beary-lint.sh [--base <ref>] [--full] [--diff-file <file>] [repo-root]"
    echo "  增量（默认）：git diff -U0 <base>...HEAD，只查新增行；--full 只计量存量，恒 exit 0。"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base)
            if [ $# -lt 2 ]; then echo "--base 缺参数" >&2; exit 2; fi
            BASE="$2"; shift 2 ;;
        --full) MODE="full"; shift ;;
        --diff-file)
            if [ $# -lt 2 ]; then echo "--diff-file 缺参数" >&2; exit 2; fi
            DIFF_FILE="$2"; MODE="difffile"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        --*) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
        *) ROOT="$1"; shift ;;
    esac
done

AWK_FILE="$(mktemp)"
trap 'rm -f "$AWK_FILE"' EXIT
cat > "$AWK_FILE" <<'AWK'
function strip_comment(line,    out, i, n, ch, in_str) {
    out = ""; in_str = 0; n = length(line)
    for (i = 1; i <= n; i++) {
        ch = substr(line, i, 1)
        if (in_str) {
            out = out ch
            if (ch == "\\" && i < n) { out = out substr(line, i + 1, 1); i++; continue }
            if (ch == "\"") in_str = 0
            continue
        }
        if (ch == "\"") { in_str = 1; out = out ch; continue }
        if (ch == "/" && i < n && substr(line, i + 1, 1) == "/") break
        out = out ch
    }
    return out
}

function is_swift(path) {
    if (index(path, "ios/App/App/") == 1) return substr(path, length(path) - 5) == ".swift"
    if (index(path, "ios/App/BearyCoreTests/") == 1) return substr(path, length(path) - 5) == ".swift"
    return 0
}

# 取紧贴在关键字赋值符后的数字；不是紧贴的（如 = bounds.height / 2）返回 ""。
function num_right_after(s, pat,    rest) {
    if (!match(s, pat)) return ""
    rest = substr(s, RSTART + RLENGTH)
    if (match(rest, /^[[:space:]]*-?[0-9]+(\.[0-9]+)?/)) return substr(rest, RSTART, RLENGTH)
    return ""
}

function has_nonzero_number(s,    rest, n) {
    rest = s
    while (match(rest, /[0-9]+(\.[0-9]+)?/)) {
        n = substr(rest, RSTART, RLENGTH)
        if ((n + 0) != 0) return 1
        rest = substr(rest, RSTART + RLENGTH)
    }
    return 0
}

function report(file, lineno, rule, hint, code) {
    total++
    count[rule]++
    printf "  %s:%d [%s] %s\n    %s\n", file, lineno, rule, hint, code
}

function check_line(file, lineno, raw,    code, n) {
    if (raw ~ /beary-lint:[[:space:]]*allow/) return
    code = strip_comment(raw)
    if (code ~ /^[[:space:]]*$/) return
    # day：裸日界 86400（BearyBeijingDay.swift 本身除外）。
    if (file != "ios/App/App/BearyBeijingDay.swift" && (code ~ /86400/ || code ~ /86_400/)) {
        report(file, lineno, "day", "裸日界 86400：走 Calendar（startOfDay/byAdding: .day）或 BearyBeijingDay", raw); return
    }
    # font：裸字号（BearyDynamicType.swift 的 token 定义本身除外）。
    if (file != "ios/App/App/BearyDynamicType.swift" && (code ~ /[Ss]ystemFont\(ofSize:[[:space:]]*[0-9]/ || code ~ /UIFont\(name:[^)]*size:[[:space:]]*[0-9]/)) {
        report(file, lineno, "font", "裸字号：走 BearyDynamicType 语义入口（diaryBodyFont/cardTitleFont/secondaryFont/captionFont/…）", raw); return
    }
    # corner：裸圆角；放行 0/1/2/8/20/999（见头注）。
    if (code ~ /cornerRadius[[:space:]]*[=:]/) {
        n = num_right_after(code, "cornerRadius[[:space:]]*[=:]")
        if (n != "" && (n + 0) != 0 && (n + 0) != 1 && (n + 0) != 2 && (n + 0) != 8 && (n + 0) != 20 && (n + 0) != 999) {
            report(file, lineno, "corner", "裸圆角：走 BearyCorners.single（12）", raw); return
        }
    }
    # duration：裸时长；放行 0 与 0.6（定位高亮渐变，规范 §6 例外）。
    n = num_right_after(code, "withDuration:")
    if (n == "" && (code ~ /animate/ || code ~ /Animator/)) n = num_right_after(code, "duration:")
    if (n != "" && (n + 0) != 0 && (n + 0) != 0.6) {
        report(file, lineno, "duration", "裸时长：走 BearyMotion（micro 0.18/normal 0.26/screen 0.38）", raw); return
    }
    # spacing：裸间距位置上的非零数字；lineSpacing（行高）除外。
    if ((code ~ /spacing[[:space:]]*:/ || code ~ /\.spacing[[:space:]]*=/ || code ~ /UIEdgeInsets\(/ || code ~ /NSDirectionalEdgeInsets\(/ || code ~ /contentInset/ || code ~ /layoutMargins/ || code ~ /sectionInset/ || code ~ /separatorInset/ || code ~ /minimumLineSpacing/ || code ~ /minimumInteritemSpacing/) && !(code ~ /lineSpacing/ && code !~ /minimumLineSpacing/)) {
        if (has_nonzero_number(code)) {
            report(file, lineno, "spacing", "裸间距：走 BearySpace（xs 4/sm 8/md 12/lg 16/xl 20/xxl 24/xxxl 32）", raw); return
        }
    }
}

BEGIN { cur_file = ""; cur_line = 0; total = 0 }

MODE == "full" {
    if (is_swift(FILENAME)) check_line(FILENAME, FNR, $0)
    next
}

/^\+\+\+ b\// { cur_file = substr($0, 7); next }
/^@@/ {
    if (match($0, /\+[0-9]+/)) cur_line = substr($0, RSTART + 1, RLENGTH - 1) + 0
    next
}
/^\+/ {
    if (cur_file != "" && is_swift(cur_file)) check_line(cur_file, cur_line, substr($0, 2))
    cur_line++
    next
}
/^-/ { next }
/^ / { cur_line++; next }
{ next }

END {
    if (MODE == "full") {
        printf "beary-lint 存量计量（只计数，不拦）：font %d，spacing %d，corner %d，duration %d，day %d，共 %d 处。\n", count["font"] + 0, count["spacing"] + 0, count["corner"] + 0, count["duration"] + 0, count["day"] + 0, total
        exit 0
    }
    if (total > 0) {
        printf "beary-lint 失败：%d 处新增违规（font %d，spacing %d，corner %d，duration %d，day %d），请改走样式 token：\n", total, count["font"] + 0, count["spacing"] + 0, count["corner"] + 0, count["duration"] + 0, count["day"] + 0
        print "说明：只拦新增行，存量不动；字号 token 见 ios/App/App/BearyDynamicType.swift，"
        print "      间距/圆角/时长 token 见 ios/App/App/BearyNativeCommon.swift 与 BearyColors.swift，"
        print "      日界 helper 见 ios/App/App/BearyBeijingDay.swift；规范见 style-token-table-final.md。"
        print "      确属例外时行尾加 // beary-lint: allow。"
        exit 1
    }
    print "beary-lint 通过：新增行里没有裸字号/裸间距/裸圆角/裸时长/裸日界。"
    exit 0
}
AWK

if [ "$MODE" = "full" ]; then
    if [ ! -d "$ROOT/ios/App/App" ]; then echo "找不到 $ROOT/ios/App/App" >&2; exit 2; fi
    LIST_FILE="$(mktemp)"
    trap 'rm -f "$AWK_FILE" "$LIST_FILE"' EXIT
    (cd "$ROOT" && find ios/App/App ios/App/BearyCoreTests -name '*.swift' -print0 2>/dev/null | sort -z > "$LIST_FILE") || exit 2
    if [ ! -s "$LIST_FILE" ]; then echo "beary-lint 存量计量：没有 Swift 文件。" ; exit 0; fi
    (cd "$ROOT" && xargs -0 awk -f "$AWK_FILE" -v MODE=full < "$LIST_FILE")
    exit 0
fi

if [ "$MODE" = "difffile" ]; then
    if [ ! -f "$DIFF_FILE" ]; then echo "找不到 diff 文件：$DIFF_FILE" >&2; exit 2; fi
    awk -f "$AWK_FILE" -v MODE=diff "$DIFF_FILE"
    exit $?
fi

# 增量模式：git diff -U0 <base>...HEAD（i18n-guard 同口径）。
# 注意 git diff 有差异时 exit 1，只把 >1 当作取 diff 失败。
DIFF_TMP="$(mktemp)"
ERR_TMP="$(mktemp)"
trap 'rm -f "$AWK_FILE" "$DIFF_TMP" "$ERR_TMP"' EXIT
rc=0
git -C "$ROOT" diff -U0 "$BASE...HEAD" -- 'ios/App/App/*.swift' 'ios/App/BearyCoreTests/*.swift' > "$DIFF_TMP" 2> "$ERR_TMP" || rc=$?
if [ "$rc" -gt 1 ]; then
    echo "取 diff 失败（base=$BASE）：$(cat "$ERR_TMP" | head -n 3)" >&2
    exit 2
fi
awk -f "$AWK_FILE" -v MODE=diff "$DIFF_TMP"
exit $?
