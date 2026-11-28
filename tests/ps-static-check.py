#!/usr/bin/env python3
"""Static checks for the Windows PowerShell scripts (see docs/DESIGN.md, section 6).

This does NOT execute PowerShell. It checks, for every .ps1 under windows/:
  1. pure ASCII content (Windows PowerShell 5.1 reads BOM-less files as ANSI);
  2. no PowerShell 7-only syntax or cmdlet options, including ConvertFrom-Json -Depth;
  3. syntax, with the tree-sitter PowerShell grammar (heuristic: this is not the
     real PowerShell parser). The grammar is required: without it the check fails;
  4. every Verb-BL* function that is called is defined in the common library
     (or in the calling file), compound verbs such as ConvertTo-BL* included;
  5. BokadorLink-* object names stay within the set fixed by the design;
  6. file names with a known extension are names of design section 4;
  7. the keywords of the ssh_config written by New-BLSshConfigText are those of
     design section 4.3, in the same order.

Exit code 0 when every check passes, 1 otherwise.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WIN = ROOT / "windows"
COMMON = WIN / "lib" / "BokadorLink.Common.ps1"
DESIGN = ROOT / "docs" / "DESIGN.md"

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
FUNC_USE = re.compile(r"(?<![\w\-])([A-Z][A-Za-z]*-BL[A-Z][A-Za-z0-9]*)\b")
OBJECT_NAME = re.compile(r"\bBokadorLink-[A-Za-z0-9]+\b")
# A file name: a name followed by an extension used by the kit. A "$" before the
# name means a variable, which is not a literal file name.
FILE_NAME = re.compile(r"(?<![\w$.\-])([A-Za-z0-9][A-Za-z0-9_.\-]*\.(?:ps1|vbs|json|log|xml|pid|flag))(?![\w.\-])")
JSON_CALL = re.compile(r"ConvertFrom-Json\b", re.I)
DEPTH_ARG = re.compile(r"-Depth\b", re.I)
SSH_LINES_BLOCK = re.compile(r"\$lines = @\(\n(.*?)\n\s*\)\n", re.S)
SSH_KEYWORD = re.compile(r"'(?: {4})?([A-Z][A-Za-z]*)(?= |')")


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


def json_depth_lines(raw_lines, code_lines):
    """Line numbers of ConvertFrom-Json calls that pass -Depth, on the line of
    the call or on its continuation lines (a line ending with a backtick)."""
    hits = []
    for index, line in enumerate(code_lines):
        if not JSON_CALL.search(line):
            continue
        last = index
        while last + 1 < len(raw_lines) and raw_lines[last].rstrip("\r").endswith("`"):
            last += 1
        if any(DEPTH_ARG.search(code_lines[j]) for j in range(index, last + 1)):
            hits.append(index + 1)
    return hits


def design_section(text, first, last):
    """Text of the design from the heading starting with first up to last."""
    start = text.index(first)
    return text[start:text.index(last, start)]


def design_file_names(text):
    """File names with a kit extension that section 4 of the design uses."""
    return set(FILE_NAME.findall(design_section(text, "\n## 4.", "\n## 5.")))


def design_ssh_keywords(text):
    """First word of each line of the code block of design section 4.3."""
    block = design_section(text, "\n### 4.3", "\n### 4.4").split("```")[1]
    return [line.split()[0] for line in block.splitlines() if line.strip()]


def generator_ssh_keywords(common_text):
    """(line, keywords) of the ssh_config lines built by New-BLSshConfigText,
    or None when that function or its line list is not found."""
    start = common_text.find("function New-BLSshConfigText")
    if start < 0:
        return None
    match = SSH_LINES_BLOCK.search(common_text, start)
    if match is None:
        return None
    line = common_text.count("\n", 0, match.start()) + 1
    return line, SSH_KEYWORD.findall(match.group(1))


def main():
    files = sorted(WIN.rglob("*.ps1"))
    problems = []
    global_problems = []
    if not files:
        print("FAIL: no .ps1 file found under windows/")
        return 1

    parser = load_parser()
    if parser is None:
        global_problems.append("tree-sitter PowerShell grammar not installed: the syntax check "
                               "cannot run (pip install tree-sitter tree-sitter-powershell)")

    design_names = None
    design_keywords = None
    try:
        design_text = DESIGN.read_text(encoding="utf-8")
        design_names = design_file_names(design_text)
        design_keywords = design_ssh_keywords(design_text)
    except (OSError, ValueError, IndexError) as error:
        global_problems.append("names of design sections 4 and 4.3 cannot be read from %s (%s)"
                               % (DESIGN.relative_to(ROOT), error))

    common_defs = set()
    common_text = ""
    if COMMON.exists():
        common_text = COMMON.read_text(encoding="latin-1")
        common_defs = set(FUNC_DEF.findall(common_text))
        if design_keywords is not None:
            found = generator_ssh_keywords(common_text)
            if found is None:
                problems.append((COMMON.relative_to(ROOT), 0,
                                 "ssh_config lines of New-BLSshConfigText not found"))
            elif found[1] != design_keywords:
                problems.append((COMMON.relative_to(ROOT), found[0],
                                 "ssh_config keywords (%s) differ from design section 4.3 (%s)"
                                 % (" ".join(found[1]), " ".join(design_keywords))))
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

        raw_lines = text.split("\n")
        code_lines = code.split("\n")
        for lineno, line in enumerate(code_lines, 1):
            for pattern, message in FORBIDDEN:
                if pattern.search(line):
                    problems.append((rel, lineno, message))
        for lineno in json_depth_lines(raw_lines, code_lines):
            problems.append((rel, lineno, "ConvertFrom-Json -Depth (PowerShell 6+ only, design section 3)"))
        if design_names is not None:
            for lineno, line in enumerate(raw_lines, 1):
                for name in FILE_NAME.findall(line):
                    if name not in design_names:
                        problems.append((rel, lineno, "file name %s is not one of design section 4" % name))

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

    for rel, lineno, message in problems:
        print("%s:%s: %s" % (rel, lineno, message))
    for message in global_problems:
        print("FAIL: " + message)
    if problems or global_problems:
        print("FAIL: %d problem(s) in %d file(s)"
              % (len(problems) + len(global_problems), len({p[0] for p in problems})))
        return 1
    print("OK: %d PowerShell file(s) checked, %d common function(s) defined, "
          "ssh_config keywords as in design section 4.3" % (len(files), len(common_defs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
