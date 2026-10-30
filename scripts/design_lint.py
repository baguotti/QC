#!/usr/bin/env python3
"""Design lint: keeps new UI code on the shared tokens in Theme.swift (see DESIGN.md).

    python3 scripts/design_lint.py            # check; exit 1 on a violation
    python3 scripts/design_lint.py --update   # after removing debt: lower the baseline

Strict rules allow no violations. Baseline rules (old debt) allow each file at most the count in
design-lint-baseline.json, so only new uses fail. A line ending in `// design-ok: <reason>` is exempt.
Theme.swift and ThemeManager.swift define the tokens and are exempt.
"""
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "VideoQCApp"
BASELINE = Path(__file__).resolve().parent / "design-lint-baseline.json"
EXEMPT_FILES = {"Theme.swift", "ThemeManager.swift"}

STRICT = {
    "animation": (re.compile(r"\.(easeInOut|easeIn|easeOut|linear|spring|interpolatingSpring|smooth|snappy|bouncy)\(|withAnimation\s*\{|withAnimation\(\)|\.animation\(\.default"),
                  "use a Motion token (sleeve, page, snap, list, fade, hover, toast, press) from Theme.swift"),
    "font": (re.compile(r"\.font\(\.system\(size:\s*[\d.]+|Font\.system\(size:\s*[\d.]+|\.font\(\.(body|callout|caption2?|footnote|headline|subheadline|title[23]?|largeTitle)\b"),
             "text: .ui(size:weight:) on the type scale; icons: .system(size: StudioTheme.scaleFont(n))"),
    "type-scale": (re.compile(r"\.ui\(size:\s*(?!(?:10|11|12|13|15|22)\b)[\d.]+"),
                   "write the step it renders at: 10, 11, 12, 13, 15 or 22"),
}
BASELINED = {
    "raw-color": (re.compile(r"\b(Color|NSColor)\((red|white|hue|calibratedRed|calibratedWhite|srgbRed|displayP3Red):"),
                  "use StudioPalette / StudioTheme colours (raw colours only for pixels drawn on media)"),
    "radius": (re.compile(r"cornerRadius:\s*[\d.]+"),
               "use Radius.control, Radius.segment or Radius.container"),
}

def code_lines(path):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or "design-ok" in line:
            continue
        yield number, line.split("//")[0] if "://" not in line else line

def scan():
    strict, counts = [], {rule: {} for rule in BASELINED}
    for path in sorted(SOURCES.glob("*.swift")):
        if path.name in EXEMPT_FILES:
            continue
        for number, line in code_lines(path):
            for rule, (pattern, fix) in STRICT.items():
                if pattern.search(line):
                    strict.append(f"{path.name}:{number}: [{rule}] {fix}\n    {line.strip()}")
            for rule, (pattern, _) in BASELINED.items():
                hits = len(pattern.findall(line))
                if hits:
                    counts[rule][path.name] = counts[rule].get(path.name, 0) + hits
    return strict, counts

def main():
    strict, counts = scan()
    if "--update" in sys.argv:
        BASELINE.write_text(json.dumps(counts, indent=2, sort_keys=True) + "\n")
        print(f"design lint: baseline written to {BASELINE.name}")
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    grown, shrunk = [], []
    for rule, (_, fix) in BASELINED.items():
        for name, count in counts[rule].items():
            allowed = baseline.get(rule, {}).get(name, 0)
            if count > allowed:
                grown.append(f"{name}: [{rule}] {count} uses, baseline {allowed}: {fix}")
        for name, allowed in baseline.get(rule, {}).items():
            if counts[rule].get(name, 0) < allowed:
                shrunk.append(f"{name}: [{rule}]")
    for message in strict + grown:
        print(message)
    if shrunk and "--update" not in sys.argv:
        print(f"design lint: debt went down in {len(shrunk)} place(s); run with --update to lock it in")
    if strict or grown:
        print(f"design lint: {len(strict) + len(grown)} violation(s). See DESIGN.md.")
        sys.exit(1)
    print("design lint: OK")

if __name__ == "__main__":
    main()
