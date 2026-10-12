#!/usr/bin/env python3
"""Checks that every Chinese UI string in Sources/ has an English entry (design.md §6.7).

Chinese source text is the lookup key, so a string added without its en.lproj entry does not
fail anywhere: it just shows up in Chinese inside the English interface. This script finds
those, plus entries whose format specifiers disagree with their key and entries no source
string uses any more.

    Scripts/check-strings.py      # exit status 1 when a string is missing or malformed

A Chinese literal is skipped when it is a `defaultValue:` (its key is the identifier before
it), the argument of Barback's own diagnostic `logSelf(…)`, inside a multi-line string, or
on a line marked `// l10n: ignore` (for text that is deliberately the same in every language,
such as a language's own name). Interpolations are compared as placeholders, so
`"\\(n) 个"` matches the key `"%lld 个"`, and so do the literal format strings handed to
`NSLocalizedString`.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
STRINGS = ROOT / "Resources" / "en.lproj" / "Localizable.strings"

HAN = re.compile(r"[㐀-鿿豈-﫿]")
SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSp])")
PLACEHOLDER = "\x00"
SKIP_CONTEXT = re.compile(r"(?:defaultValue:\s*|logSelf\(\s*)$")
IGNORE_MARKER = "// l10n: ignore"


def swift_literals(line):
    """Yields (literal text with interpolations replaced, text before the literal) for each
    single-line string literal on `line`, ignoring a trailing `//` comment."""
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if line.startswith("//", i):
            return
        if c != '"':
            i += 1
            continue
        start = i
        i += 1
        out = []
        while i < n and line[i] != '"':
            if line[i] == "\\" and i + 1 < n:
                if line[i + 1] == "(":
                    # Skip a balanced interpolation, including any nested string literals.
                    depth, i = 1, i + 2
                    while i < n and depth:
                        if line[i] == '"':
                            i += 1
                            while i < n and line[i] != '"':
                                i += 2 if line[i] == "\\" else 1
                        elif line[i] == "(":
                            depth += 1
                        elif line[i] == ")":
                            depth -= 1
                        i += 1
                    out.append(PLACEHOLDER)
                    continue
                out.append(line[i:i + 2])
                i += 2
                continue
            out.append(line[i])
            i += 1
        i += 1
        yield "".join(out), line[:start]


def normalize_key(key):
    return SPECIFIER.sub(PLACEHOLDER, key.replace("%%", "%"))


def specifier_types(text):
    """Conversion types in argument order, honouring positional `%2$@` specifiers."""
    found = [(m.group(1), (m.group(2) or "") + m.group(3)) for m in SPECIFIER.finditer(text.replace("%%", ""))]
    if any(pos for pos, _ in found):
        return [t for _, t in sorted(found, key=lambda f: int(f[0] or 0))]
    return [t for _, t in found]


def parse_strings(path):
    text = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
    entries, problems = {}, []
    entry = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";$')
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        m = entry.match(line)
        if not m:
            problems.append(f"{path.relative_to(ROOT)}:{number}: unparseable line: {line}")
            continue
        key, value = m.groups()
        if key in entries:
            problems.append(f"{path.relative_to(ROOT)}:{number}: duplicate key: {key}")
        entries[key] = value
    return entries, problems


def main():
    entries, problems = parse_strings(STRINGS)
    for key, value in entries.items():
        if specifier_types(key) != specifier_types(value):
            problems.append(f"format specifiers differ: \"{key}\" = \"{value}\"")
    # The interpolated value's type is unknown here, so "%@" and "%d" variants of one text
    # both match it.
    keys = {}
    for key in entries:
        keys.setdefault(normalize_key(key), []).append(key)

    used, missing = set(), []
    for path in sorted(SOURCES.rglob("*.swift")):
        in_multiline = False
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.count('"""') % 2:
                in_multiline = not in_multiline
                continue
            if in_multiline:
                continue
            for literal, before in swift_literals(line):
                literal = normalize_key(literal)
                used.update(keys.get(literal, []))
                if not HAN.search(literal) or literal in keys:
                    continue
                if SKIP_CONTEXT.search(before) or IGNORE_MARKER in line:
                    continue
                missing.append(f"{path.relative_to(ROOT)}:{number}: {literal.replace(PLACEHOLDER, '%@')}")

    unused = sorted(set(entries) - used)
    for item in missing:
        print(f"missing English entry: {item}")
    for item in problems:
        print(f"error: {item}")
    for key in unused:
        print(f"warning: unused entry: {key}")
    print(f"{len(entries)} entries, {len(missing)} missing, {len(problems)} errors, {len(unused)} unused")
    return 1 if missing or problems else 0


if __name__ == "__main__":
    sys.exit(main())
