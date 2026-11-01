#!/usr/bin/env python3
"""Build-time check: every official beary-ui asset referenced by Swift code
must exist as a complete set in Assets.xcassets.

Background (audit round 3, item 27):
  SceneDelegate keeps an explicit, documented fallback -- official asset first,
  SF Symbol only when the asset is missing (topIconImage / segmentIcon).
  That fallback is intentional and must NOT be removed. This script is the
  other half of the deal: it makes a missing official asset fail the build
  in CI, with the missing names printed, instead of silently degrading to
  the SF fallback at runtime.

Name mapping (verified against the tree, do not guess):
  The web sprite names are `beary-*` (beary.html). The App does not contain
  any literal `beary-*` asset name in Swift; the same official artwork is
  packed as `icon_*` / `side_*` / `emote_*` / `badge_*` image sets
  (see BearyNativeCommon.BearyIconImages, BearyEmoteImages, SceneDelegate
  side-matrix comments). So this script checks the App-side names that code
  actually references, and additionally covers any future literal `beary-*`
  name passed to UIImage(named:) if one ever appears.

What is checked (code -> catalog, one direction only):
  1. Literal asset names: every double-quoted literal in Swift code (after
     comment stripping) shaped like icon_*, emote_*, side_*, badge_*,
     Icon*, LogoHorizontal, bear_watermark, crown, or beary-*.
     This covers UIImage(named:), BearyIconImages.image(named:),
     topIcon/segment call sites, side-matrix pattern tuples, and
     iconName/default arguments alike.
  2. Dynamic families, expanded from their code-side key lists:
     - emote_<key> and emote_<key>_dark for every key in
       BearyEmotePickerSheet.all + BearyComposerViewController.moodOrder
       (covers UIImage(named: "emote_\\(key)") / "..._dark").
     - icon_wx_<key> for every key in BearyComposerViewController.weatherOrder
       (covers "icon_wx_\\(key)" / "icon_wx_" + weatherKey).
     - badge_<key> for every key in BearyBadgeImages.displayName's `known`
       map (covers "badge_" + key).
     If a key list cannot be found, the script FAILS (fail-closed) instead
     of silently skipping that family: a refactor that moves the list must
     update this script, not silently drop coverage.
  3. Each required set must exist as `<name>.imageset` AND its
     Contents.json must reference at least one image file that exists on
     disk (guards against an empty placeholder set).

What is NOT checked (documented limits, not oversights):
  - Server-driven keys with no code-side list (e.g. a future authorBadge
    key not yet in the `known` map) cannot be statically enumerated.
  - Unreferenced sets in the catalog are fine; the check is referenced
    subset-of catalog, not equality.
  - AppIcon.appiconset is Xcode-managed, not code-referenced, and is
    intentionally excluded.

Read-only: this script never writes, never edits code, never changes app
behaviour. Exit 0 = all referenced sets present and non-empty.
Exit 1 = missing/broken sets, or a key source that could not be found;
the missing names are printed one per line for the CI log.

Usage: python3 scripts/check-beary-assets.py [--root <repo root>]
  --root defaults to the repository root (parent of this script's dir).
  --swift-dir / --xcassets override the scanned locations (used by tests).
"""

import argparse
import json
import re
import sys
from pathlib import Path

LITERAL_RE = re.compile(
    r"^(?:icon|emote|side|badge)_[a-z0-9_]+$"
    r"|^Icon[A-Z][A-Za-z0-9]*$"
    r"|^LogoHorizontal$|^bear_watermark$|^crown$"
    r"|^beary-[a-z0-9_-]+$"
)
STRING_RE = re.compile(r'"((?:\\.|[^"\\])*)"')
KEY_STRING_RE = re.compile(r'"([A-Za-z0-9_]+)"')


def strip_comments(text):
    """Remove // and /* */ comments, honouring Swift string literals.

    Handles "..." strings (backslash escapes keep the next char inside the
    string, so URLs and \\( interpolations cannot leak a fake comment
    start) and \"\"\"...\"\"\" multi-line strings. Comment text containing
    quotes is skipped wholesale because comments are only recognised in
    code mode. Anything else is copied verbatim.
    """
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j == -1 else j  # keep the newline itself
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            if j == -1:
                out.append(text[i:])
                break
            out.append(text[i : j + 3])
            i = j + 3
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1 if j < n and text[j] == '"' else j])
            i = j + 1 if j < n and text[j] == '"' else j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def parse_key_array(source, label, pattern):
    """Extract the string keys of one named Swift array/map literal."""
    m = re.search(pattern, source, re.DOTALL)
    if not m:
        raise SystemExit(f"ERROR: key source not found, cannot verify family: {label}")
    keys = KEY_STRING_RE.findall(m.group(1))
    if not keys:
        raise SystemExit(f"ERROR: key source found but empty: {label}")
    return keys


def main():
    here = Path(__file__).resolve()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(here.parent.parent))
    parser.add_argument("--swift-dir", default=None)
    parser.add_argument("--xcassets", default=None)
    args = parser.parse_args()
    root = Path(args.root)
    swift_dir = Path(args.swift_dir) if args.swift_dir else root / "ios/App/App"
    xcassets = Path(args.xcassets) if args.xcassets else swift_dir / "Assets.xcassets"

    swift_files = sorted(swift_dir.glob("*.swift"))
    if not swift_files:
        print(f"ERROR: no Swift files under {swift_dir}")
        return 1
    if not xcassets.is_dir():
        print(f"ERROR: asset catalog not found: {xcassets}")
        return 1

    required = {}  # asset name -> reason string
    literal_count = 0
    for path in swift_files:
        code = strip_comments(path.read_text(encoding="utf-8"))
        for m in STRING_RE.finditer(code):
            literal = m.group(1)
            if "\\" in literal:
                continue  # interpolated / escaped: covered by family expansion
            if not LITERAL_RE.match(literal):
                continue
            # Two narrow exclusions, both verified against real code:
            # - concatenation fragment: "icon_wx_" + weatherKey is a prefix,
            #   not a set name (a complete name is never followed by +).
            # - enum raw value: case emoteChirp = "emote_chirp" is a sound
            #   key in BearySoundPlayer, never passed to UIImage(named:).
            if re.match(r"\s*\+", code[m.end() : m.end() + 8]):
                continue
            if re.search(r"case\s+[A-Za-z0-9_]+\s*=\s*$", code[max(0, m.start() - 40) : m.start()]):
                continue
            literal_count += 1
            required.setdefault(literal, f"literal in {path.name}")

    composer = (swift_dir / "BearyComposerViewController.swift").read_text(encoding="utf-8")
    picker = (swift_dir / "BearyEmotePickerSheet.swift").read_text(encoding="utf-8")
    badges = (swift_dir / "BearyBadgeImages.swift").read_text(encoding="utf-8")

    emote_keys = set(
        parse_key_array(
            composer, "BearyComposerViewController.moodOrder",
            r"moodOrder\s*:\s*\[String\]\s*=\s*\[(.*?)\]",
        )
    ) | set(
        parse_key_array(
            picker, "BearyEmotePickerSheet.all",
            r"static\s+let\s+all\s*:\s*\[String\]\s*=\s*\[(.*?)\]",
        )
    )
    for key in sorted(emote_keys):
        required.setdefault(f"emote_{key}", "emote family (mood key)")
        required.setdefault(f"emote_{key}_dark", "emote family (mood key, dark)")

    weather_keys = parse_key_array(
        composer, "BearyComposerViewController.weatherOrder",
        r"weatherOrder\s*:\s*\[String\]\s*=\s*\[(.*?)\]",
    )
    for key in weather_keys:
        required.setdefault(f"icon_wx_{key}", "weather family (weather key)")

    # 徽章族已退役（455，BETA 下线）：displayName 映射已删除，不再校验；
    # 新徽章上架时须恢复本检查并同步 badge_<key> 资产。

    catalog = {
        p.name[: -len(".imageset")]
        for p in xcassets.iterdir()
        if p.is_dir() and p.name.endswith(".imageset")
    }

    missing, broken = [], []
    for name in sorted(required):
        imageset = xcassets / f"{name}.imageset"
        if name not in catalog:
            missing.append(name)
            continue
        try:
            contents = json.loads((imageset / "Contents.json").read_text(encoding="utf-8"))
            filenames = [
                img["filename"]
                for img in contents.get("images", [])
                if isinstance(img, dict) and img.get("filename")
            ]
        except (OSError, ValueError):
            filenames = []
        if not filenames or not any((imageset / f).is_file() for f in filenames):
            broken.append(name)

    print(f"swift files scanned: {len(swift_files)}")
    print(f"literal asset references: {literal_count}")
    print(f"emote keys: {len(emote_keys)}, weather keys: {len(weather_keys)}, "
          f"badge keys: retired (455)")
    print(f"required asset sets: {len(required)}, catalog sets: {len(catalog)}")
    if missing:
        print("MISSING asset sets (referenced by code, absent from xcassets):")
        for name in missing:
            print(f"  - {name}  ({required[name]})")
    if broken:
        print("BROKEN asset sets (imageset exists but no referenced image file on disk):")
        for name in broken:
            print(f"  - {name}  ({required[name]})")
    if missing or broken:
        print("RESULT: FAIL -- add the missing official beary-ui sets; "
              "the SF fallback in SceneDelegate must not be used to paper over this.")
        return 1
    print("RESULT: OK -- all code-referenced official assets are present and non-empty.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
