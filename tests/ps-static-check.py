#!/usr/bin/env python3
"""Static checks for the Windows PowerShell scripts (see docs/DESIGN.md, section 6).

This does NOT execute PowerShell. It checks, for every .ps1 under windows/:
  1. pure ASCII content (Windows PowerShell 5.1 reads BOM-less files as ANSI);
  2. no PowerShell 7-only syntax or cmdlet options;
  3. syntax, with the tree-sitter PowerShell grammar (heuristic: this is not the
     real PowerShell parser; skipped with a warning if the grammar is not installed);
  4. every Verb-BL* function that is called is defined in the common library
     (or in the calling file);
  5. BokadorLink-* object names stay within the set fixed by the design.

Exit code 0 when every check passes, 1 otherwise.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WIN = ROOT / "windows"
COMMON = WIN / "lib" / "BokadorLink.Common.ps1"

ALLOWED_OBJECT_NAMES = {"BokadorLink-Tunnel", "BokadorLink-Watchdog", "BokadorLink-Supervisor"}

FORBIDDEN = [
    (re.compile(r"\?\?"), "null-coalescing operator '??' (PowerShell 7 only)"),
    (re.compile(r"\?\.\w"), "null-conditional operator '?.' (PowerShell 7 only)"),
    (re.compile(r"&&"), "pipeline chain operator '&&' (PowerShell 7 only)"),
    (re.compile(r"\|\|"), "pipeline chain operator '||' (PowerShell 7 only)"),
    (re.compile(r"-Parallel\b", re.I), "ForEach-Object -Parallel (PowerShell 7 only)"),
    (re.compile(r"\bJoin-String\b", re.I), "Join-String (PowerShell 7 only)"),
    (re.compile(r"-AsHashtable\b", re.I), "ConvertFrom-Json -AsHashtable (PowerShell 7 only)"),
    (re.compile(r"[\)\w\]'\"]\s\?\s[^|]+\s:\s"), "ternary operator (PowerShell 7 only)"),
    (re.compile(r"\bStart-Process\b", re.I), "Start-Process (use Invoke-BLNative, design section 3)"),
]

FUNC_DEF = re.compile(r"^\s*function\s+([A-Za-z]+-BL[A-Za-z0-9]+)\b", re.M)
FUNC_USE = re.compile(r"(?<![\w\-])([A-Z][a-z]+-BL[A-Z][A-Za-z0-9]+)\b")
OBJECT_NAME = re.compile(r"\bBokadorLink-[A-Za-z0-9]+\b")


def strip_code(text):
    """Blank out comments and string literals, keeping line structure.

    Good enough for token-level heuristics; not a full PowerShell lexer.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if two == "<#":
            j = text.find("#>", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif two in ("@\"", "@'"):
            term = "\n" + two[1] + "@"
            j = text.find(term, i + 2)
            j = n if j < 0 else j + len(term)
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c == "#":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif c == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if text[j:j + 2] == "''":
                        j += 2
                        continue
                    break
                j += 1
            j = min(j + 1, n)
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c == '"':
            j = i + 1
            while j < n:
                if text[j] == "`":
                    j += 2
                    continue
                if text[j] == '"':
                    if text[j:j + 2] == '""':
                        j += 2
                        continue
                    break
                j += 1
            j = min(j + 1, n)
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c == "`" and i + 1 < n:
            out.append("  " if text[i + 1] != "\n" else " \n")
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def load_parser():
    try:
        import tree_sitter_powershell as tsp
        from tree_sitter import Language, Parser
    except ImportError:
        return None
    return Parser(Language(tsp.language()))


def syntax_errors(parser, data):
    errors = []
    tree = parser.parse(data)

    def walk(node):
        if node.type == "ERROR" or node.is_missing:
            kind = "missing " + node.type if node.is_missing else "syntax error"
            snippet = data[node.start_byte:node.start_byte + 50].decode("ascii", "replace")
            errors.append((node.start_point[0] + 1, kind, snippet.split("\n")[0]))
        for child in node.children:
            walk(child)

    if tree.root_node.has_error:
        walk(tree.root_node)
    return errors


def main():
    files = sorted(WIN.rglob("*.ps1"))
    problems = []
    notes = []
    if not files:
        print("FAIL: no .ps1 file found under windows/")
        return 1

    parser = load_parser()
    if parser is None:
        notes.append("tree-sitter PowerShell grammar not installed: syntax check SKIPPED "
                     "(pip install tree-sitter tree-sitter-powershell)")

    common_defs = set()
    if COMMON.exists():
        common_defs = set(FUNC_DEF.findall(COMMON.read_text(encoding="latin-1")))
    else:
        problems.append((COMMON, 0, "common library is missing"))

    for path in files + sorted(WIN.rglob("*.vbs")):
        rel = path.relative_to(ROOT)
        data = path.read_bytes()

        for lineno, line in enumerate(data.split(b"\n"), 1):
            bad = [b for b in line if b > 126 or (b < 32 and b not in (9, 13))]
            if bad:
                problems.append((rel, lineno, "non-ASCII or control byte 0x%02x" % bad[0]))
        if data.startswith(b"\xef\xbb\xbf"):
            problems.append((rel, 1, "UTF-8 BOM present (files must be plain ASCII)"))

        if path.suffix != ".ps1":
            continue

        text = data.decode("latin-1")
        code = strip_code(text)

        for lineno, line in enumerate(code.split("\n"), 1):
            for pattern, message in FORBIDDEN:
                if pattern.search(line):
                    problems.append((rel, lineno, message))

        local_defs = set(FUNC_DEF.findall(text))
        for lineno, line in enumerate(code.split("\n"), 1):
            for name in FUNC_USE.findall(line):
                if name not in common_defs and name not in local_defs:
                    problems.append((rel, lineno, "call to undefined function %s" % name))

        for lineno, line in enumerate(text.split("\n"), 1):
            for name in OBJECT_NAME.findall(line):
                if name not in ALLOWED_OBJECT_NAMES:
                    problems.append((rel, lineno, "unexpected object name %s" % name))

        if parser is not None:
            for lineno, kind, snippet in syntax_errors(parser, data):
                problems.append((rel, lineno, "%s near: %s" % (kind, snippet)))

    for note in notes:
        print("NOTE: " + note)
    if problems:
        for rel, lineno, message in problems:
            print("%s:%s: %s" % (rel, lineno, message))
        print("FAIL: %d problem(s) in %d file(s)" % (len(problems), len({p[0] for p in problems})))
        return 1
    print("OK: %d PowerShell file(s) checked, %d common function(s) defined"
          % (len(files), len(common_defs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
