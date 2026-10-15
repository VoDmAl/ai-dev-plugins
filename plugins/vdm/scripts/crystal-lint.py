#!/usr/bin/env python3
"""crystal-lint.py — structural validator for crystal workitems.

Pure-stdlib parser. All environment resolution (roots, template path, status
taxonomy, aliases) is done by the shell wrapper and handed over via env, the
same split crystal-completion-guard.sh/.py uses.

THE CANON IS NOT HARDCODED HERE. It is derived, every run, from the workitem
template — the file agents are told to copy. That makes the signal what every
detector in this suite is: a comparison of two artifacts that are on disk
anyway (see docs/model/suite.md → "Один сигнал"). Three properties fall out:

  * one source of truth — the template cannot disagree with the linter;
  * localizable — translate the template's headings and the linter follows;
  * stateless — nothing to migrate, nothing that can go stale.

Canon markers IN THE TEMPLATE:
  * `## Heading <!-- crystal-lint: optional -->` — section is not required.
  * `**Field:** ... (optional ...)`               — DL field is not required.
  * `**Basis:** {{a | b | c}}`                    — enumerates allowed values.

Scope (crystal-canon-enforcement DL #3): only NON-TERMINAL workitems are
checked. A done/cancelled/superseded workitem is a historical record; rewriting
it to satisfy a newer canon falsifies the record, exactly as touching a
synthesis doc falsifies its `observed:` date. Verified against this repo's own
tree: 4 of 6 workitems predate the `## Текущая модель` section (added
2026-07-13) and all 4 are `done`.

Reporting rule (DL #4): canon is a FLOOR. Only MISSING required things are
reported. Extra sections and extra frontmatter keys are legal — that is what
lets a host repo impose its own conventions without conflicting.

Env contract (all optional except CRYSTAL_TEMPLATE):
  CRYSTAL_TEMPLATE     path to workitem-template.md            (required)
  CRYSTAL_TERMINAL     comma-separated terminal statuses       (default: done,cancelled,superseded)
  CRYSTAL_CANONICAL    comma-separated canonical statuses      (default: the 9 canonical ones)
  CRYSTAL_ALIASES      comma-separated `from=to` status aliases

Exit: 0 = clean, 1 = violations found, 2 = usage error, 3 = no verdict.

Two readings of one file (canon-gate-scope). The plain one reports everything
off canon — the debt, for `--all`, `crystal-cave` and a person. The gate
(`--pre-tool-use`, `--against`) compares the file before and after an edit and
reports only what the edit may not leave behind: the structure in full, and in
the Decision Log and the promises only what is new. See `blocking()`.
"""

import os
import re
import sys

DEFAULT_TERMINAL = "done,cancelled,superseded"
DEFAULT_CANONICAL = (
    "idea,draft,ready,in-progress,blocked,dormant,done,cancelled,superseded"
)

# A heading line, with any trailing HTML comment kept separate so the marker
# never becomes part of the heading text.
H2_RE = re.compile(r"^##\s+(.*?)\s*(<!--.*?-->)?\s*$")
DL_HEAD_RE = re.compile(r"^###\s+#(\d+)\s*/\s*(\S+)\s*/\s*(.+?)\s*$")
DL_HEAD_STRICT_RE = re.compile(r"^###\s+#\d+\s+/\s+\d{4}-\d{2}-\d{2}\s+/\s+\S")
FIELD_RE = re.compile(r"^\*\*([^*:]+):\*\*\s*(.*)$")
LINT_OPTIONAL_RE = re.compile(r"crystal-lint:\s*optional")
ENUM_RE = re.compile(r"\{\{(.+?)\}\}")


def split_frontmatter(text):
    """Return (frontmatter_lines, body_lines). Empty frontmatter if absent."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return [], lines
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return lines[1:i], lines[i + 1 :]
    return [], lines


def frontmatter_keys(fm_lines):
    """Uncommented top-level keys, in order. Commented ones are optional."""
    keys = []
    for line in fm_lines:
        if line.startswith("#") or not line.strip():
            continue
        if line[:1].isspace():  # nested value (list item / block scalar)
            continue
        m = re.match(r"^([A-Za-z0-9_-]+)\s*:", line)
        if m and m.group(1) not in keys:
            keys.append(m.group(1))
    return keys


def frontmatter_value(fm_lines, key):
    for line in fm_lines:
        if line.startswith("#"):
            continue
        m = re.match(r"^" + re.escape(key) + r"\s*:\s*(.*)$", line)
        if m:
            return m.group(1).strip().strip("\"'")
    return None


def headings(body_lines):
    """[(text, is_optional)] for every H2 in order."""
    out = []
    for line in body_lines:
        m = H2_RE.match(line)
        if not m:
            continue
        text = m.group(1).strip()
        comment = m.group(2) or ""
        out.append((text, bool(LINT_OPTIONAL_RE.search(comment))))
    return out


def parse_canon(template_text):
    """Derive the canon from the template.

    Returns dict with: sections (required), optional_sections, fm_keys,
    dl_fields (required), basis_values (allowed enum or None).
    """
    fm, body = split_frontmatter(template_text)
    req_sections, opt_sections = [], []
    for text, optional in headings(body):
        (opt_sections if optional else req_sections).append(text)

    dl_required, basis_values = [], None
    in_dl = False
    for line in body:
        m = H2_RE.match(line)
        if m:
            in_dl = m.group(1).strip() == "Decision Log"
            continue
        if not in_dl:
            continue
        fm_field = FIELD_RE.match(line)
        if not fm_field:
            continue
        name, rest = fm_field.group(1).strip(), fm_field.group(2)
        if name == "Basis":
            enum = ENUM_RE.search(rest)
            if enum:
                basis_values = [v.strip() for v in enum.group(1).split("|") if v.strip()]
        if "(optional" in rest:
            continue
        if name not in dl_required:
            dl_required.append(name)

    return {
        "sections": req_sections,
        "optional_sections": opt_sections,
        "fm_keys": frontmatter_keys(fm),
        "dl_fields": dl_required,
        "basis_values": basis_values,
    }


# A promise may carry the date it was promised for: `- [ ] do it (due: 2026-07-22)`.
# Absent is LEGAL — most promises have no external timer, and demanding a date
# would produce invented ones (checkbox-decay-signal DL #2). MALFORMED is not:
# `(due: soon)` or `(due: 22-07-2026)` reads as a deadline to a human and is
# invisible to the overdue check, which is this repository's recurring failure —
# a mechanism that silently narrows its own scope. So the canon requires nothing
# and rejects only what claims to be a projection without being one.
#
# A date reads in three spellings: `(due: …)`, and the vdm-comms ledger's
# `[due:: …]` and `⏰ …` — the same ones as `_VDM_DUE_RE` in lib/crystal-path.sh
# (vdm-comms-commitment-form DL #4). A broken `[due:: soon]` is malformed like a
# broken `(due: soon)`; `⏰` alone claims nothing, since `⏰ after:` is an event.
DUE_OK_RE = re.compile(
    r"\(due:\s*\d{4}-\d{2}-\d{2}\s*\)"
    r"|\[due::\s*\d{4}-\d{2}-\d{2}\s*\]"
    r"|⏰\s*\d{4}-\d{2}-\d{2}"
)
DUE_ANY_RE = re.compile(r"\(due:|\[due::")
UNCHECKED_RE = re.compile(r"^[ \t]*-[ \t]*\[[ \t]\]")
CHECKBOX_RE = re.compile(r"^[ \t]*-[ \t]*\[([ \t]|x|X)\]")
FENCE_RE = re.compile(r"^[ \t]*(```|~~~)")


def _indent(line):
    return len(line) - len(line.lstrip(" \t"))


def unchecked_items(body_lines):
    """One string per unchecked item outside a fence: the checkbox line with its
    continuation joined on (crystal-wake DL #1).

    Hard-wrapped items put the `(due:)` that closes the sentence on the last,
    wrapped line; read line by line it was invisible. The continuation is every
    line deeper than the checkbox, blank lines inside included; it ends at a line
    no deeper, at the next checkbox (a nested one owns its own text), or at a
    fence that is no deeper. Same model as `_unchecked_lines` in
    lib/crystal-path.sh; the two are compared by "malformed dates — the lint and
    the lib read the same items" in tests/crystal-lint.test.sh.
    """
    items, cur, ind, fence = [], None, 0, False
    for raw in body_lines:
        line = raw.rstrip("\r\n")
        if FENCE_RE.match(line):
            if cur is not None and _indent(line) <= ind:
                items.append(cur)
                cur = None
            fence = not fence
            continue
        if fence:
            continue
        if CHECKBOX_RE.match(line):
            if cur is not None:
                items.append(cur)
            ind = _indent(line)
            cur = line if UNCHECKED_RE.match(line) else None
            continue
        if cur is None or not line.strip():
            continue
        if _indent(line) > ind:
            cur += " " + line.strip()
        else:
            items.append(cur)
            cur = None
    if cur is not None:
        items.append(cur)
    return items


def malformed_due(body_lines):
    """Unchecked items whose `due:` marker is not an ISO date — wherever in the
    item it stands. Fenced blocks are skipped: a checkbox inside ``` is the
    format being documented, not a promise being made."""
    return [item.strip() for item in unchecked_items(body_lines)
            if DUE_ANY_RE.search(item) and not DUE_OK_RE.search(item)]


def dl_entries(body_lines):
    """[(lineno, heading_line, [body lines])] for entries under ## Decision Log."""
    entries, in_dl, current = [], False, None
    for idx, line in enumerate(body_lines, start=1):
        m = H2_RE.match(line)
        if m:
            in_dl = m.group(1).strip() == "Decision Log"
            current = None
            continue
        if not in_dl:
            continue
        if line.startswith("### "):
            current = (idx, line.rstrip(), [])
            entries.append(current)
        elif current is not None:
            current[2].append(line)
    return entries


def declares_itself_a_workitem(path):
    """A file named workitem.md claims the canon by its name alone.

    Any other .md sitting in a crystal root is an artifact until it says
    otherwise — the same rule lib/crystal-path.sh already applies in
    filter_status() and audit_non_canonical(), where files without a `status:`
    key are dropped rather than reported as broken workitems. Keeping the two
    in agreement matters: a linter that flags every stray note in tasks/ gets
    switched off, and a gate nobody runs is a gate that does not exist.
    """
    return os.path.basename(path) == "workitem.md"


# What a finding belongs to — the line the blocking gate draws (canon-gate-scope
# DL #2, #6). STRUCTURE is the file's shape: sections, frontmatter keys, the
# status, a log with no entries. Supplying it asserts nothing, so it is owed in
# full at every edit. ENTRY is anything inside a Decision Log entry — heading,
# fields, the Basis value — and DUE is a malformed date in a promise. Fixing
# either in a past entry or someone else's item means writing a claim nobody
# can stand behind, and the log is append-only besides, so the gate checks them
# only where they are new.
STRUCTURE, ENTRY, DUE = "structure", "entry", "due"
DUE_HINT = "malformed `due:` marker(s) — expected `(due: YYYY-MM-DD)` or `[due:: YYYY-MM-DD]`:\n    %s"


def findings(path, text, canon, terminal, canonical, aliases, history=True):
    """Return (status_label, [(scope, key, message)]).

    `key` says which part of the file a finding is about: None for STRUCTURE;
    for ENTRY, ("n", number, heading) when the heading carries `#N`, else
    ("h", heading); for DUE, the list of malformed items.

    history=False: the file has no earlier state, so a terminal status exempts
    nothing — a workitem born `done` has no record to protect (DL #7).
    """
    fm, body = split_frontmatter(text)
    out = []
    named_workitem = declares_itself_a_workitem(path)

    def structure(message):
        out.append((STRUCTURE, None, message))

    if not fm:
        if not named_workitem:
            return "skipped-artifact", []
        structure("no YAML frontmatter — not a workitem shape at all")
        return "checked", out

    raw_status = frontmatter_value(fm, "status")
    if raw_status is None:
        if not named_workitem:
            return "skipped-artifact", []
        structure("frontmatter has no `status:` key")
        return "checked", out
    status = aliases.get(raw_status, raw_status)

    if status in terminal and history:
        return "skipped-terminal", []

    if frontmatter_value(fm, "crystal-schema") == "legacy":
        return "legacy", []

    if status not in canonical:
        structure(
            "`status: %s` is not in the canonical taxonomy (%s)"
            % (raw_status, ", ".join(sorted(canonical)))
        )

    # --- frontmatter keys (floor: missing only) -----------------------------
    present_keys = frontmatter_keys(fm)
    missing_keys = [k for k in canon["fm_keys"] if k not in present_keys]
    if missing_keys:
        structure("frontmatter missing: %s" % ", ".join(missing_keys))

    # --- sections (floor: missing only) -------------------------------------
    present = [text_ for text_, _ in headings(body)]
    missing = [s for s in canon["sections"] if s not in present]
    if missing:
        structure(
            "missing required section(s): %s"
            % ", ".join("## " + s for s in missing)
        )

    # --- Decision Log entries ------------------------------------------------
    if "Decision Log" in present:
        entries = dl_entries(body)
        if not entries:
            structure("`## Decision Log` present but contains no `### #N / …` entries")
        for lineno, heading, entry_body in entries:
            label = heading.strip()
            num = DL_HEAD_RE.match(heading)
            key = ("n", num.group(1), label) if num else ("h", label)
            if not DL_HEAD_STRICT_RE.match(heading):
                out.append((ENTRY, key,
                    "DL entry heading is not `### #N / YYYY-MM-DD / title`: %r" % label
                ))
                continue
            fields = {}
            for line in entry_body:
                m = FIELD_RE.match(line)
                if m:
                    fields[m.group(1).strip()] = m.group(2).strip()
            absent = [f for f in canon["dl_fields"] if f not in fields]
            if absent:
                out.append((ENTRY, key,
                    "DL entry %s missing field(s): %s"
                    % (label.replace("### ", ""), ", ".join(absent))
                ))
            basis = fields.get("Basis")
            allowed = canon["basis_values"]
            if basis and allowed and basis not in allowed:
                out.append((ENTRY, key,
                    "DL entry %s has `Basis: %s` — allowed: %s"
                    % (label.replace("### ", ""), basis, ", ".join(allowed))
                ))

    # --- due markers (floor: absent is legal, malformed is not) -------------
    bad_due = malformed_due(body)
    if bad_due:
        out.append((DUE, bad_due, DUE_HINT % "\n    ".join(bad_due[:5])))

    return "checked", out


def lint(path, text, canon, terminal, canonical, aliases):
    """Return (status_label, [problem strings]) — everything off canon."""
    label, found = findings(path, text, canon, terminal, canonical, aliases)
    return label, [message for _, _, message in found]


def _entry_identities(text):
    """(Counter of entry numbers, set of heading lines) under ## Decision Log."""
    from collections import Counter
    numbers, heads = Counter(), set()
    for _, heading, _ in dl_entries(split_frontmatter(text)[1]):
        heads.add(heading.strip())
        m = DL_HEAD_RE.match(heading)
        if m:
            numbers[m.group(1)] += 1
    return numbers, heads


def blocking(path, before, after, canon, terminal, canonical, aliases):
    """Return (status_label, [problem strings]) that an edit from `before` to
    `after` may not leave behind. `before` is None for a file that did not exist.

    Two states compared, no dates and no markers (DL #1): STRUCTURE is owed in
    full; an ENTRY finding only for an entry the earlier state did not have, and
    a DUE finding only for an item that was not already malformed. An entry is
    known by its number, the way only_new_orphans in crystal-lint.sh knows a
    sidetrack card — a retitled entry is the same entry. When a number repeats,
    the new entries under it are the ones whose heading the earlier state did
    not have; a heading with no `#N` is known by its text (DL #6).
    """
    label, found = findings(path, after, canon, terminal, canonical, aliases,
                            history=before is not None)
    if label != "checked":
        return label, []
    if before is None:
        return label, [message for _, _, message in found]

    was_numbers, was_heads = _entry_identities(before)
    now_numbers, _ = _entry_identities(after)
    was_due = set(malformed_due(split_frontmatter(before)[1]))
    out = []
    for scope, key, message in found:
        if scope == STRUCTURE:
            out.append(message)
        elif scope == ENTRY:
            if key[0] == "n":
                _, number, heading = key
                if number not in was_numbers or (
                    now_numbers[number] > was_numbers[number] and heading not in was_heads
                ):
                    out.append(message)
            elif key[1] not in was_heads:
                out.append(message)
        elif scope == DUE:
            new = [item for item in key if item not in was_due]
            if new:
                out.append(DUE_HINT % "\n    ".join(new[:5]))
    return label, out


def _post_edit_content(tool_name, tool_input, path):
    """What the file will hold after the tool runs, or None to skip.

    Borrowed from crystal-completion-guard.py rather than copied: two answers to
    "what will this edit leave on disk" would drift, and that guard's answer is
    the one that already gates every workitem write. Loaded by path, since a
    file name with a hyphen cannot be imported by name.
    """
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(
        "crystal_completion_guard", os.path.join(here, "crystal-completion-guard.py"))
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    return guard._build_post_edit_content(tool_name, tool_input, path)


def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def _report(path, problems):
    sys.stderr.write("%s\n" % path)
    for p in problems:
        sys.stderr.write("  ✗ %s\n" % p)


def csv_env(name, default=""):
    return [v.strip() for v in os.environ.get(name, default).split(",") if v.strip()]


def main(argv):
    template_path = os.environ.get("CRYSTAL_TEMPLATE", "")
    if not template_path or not os.path.isfile(template_path):
        # Fail-open: without the canon there is nothing to compare against.
        return 0

    try:
        with open(template_path, encoding="utf-8") as fh:
            canon = parse_canon(fh.read())
    except OSError:
        return 0

    if "--print-canon" in argv:
        print("# canon derived from: %s" % template_path)
        for s in canon["sections"]:
            print("section\t%s" % s)
        for s in canon["optional_sections"]:
            print("section-optional\t%s" % s)
        for k in canon["fm_keys"]:
            print("frontmatter\t%s" % k)
        for f in canon["dl_fields"]:
            print("dl-field\t%s" % f)
        for v in canon["basis_values"] or []:
            print("basis-value\t%s" % v)
        return 0

    terminal = set(csv_env("CRYSTAL_TERMINAL", DEFAULT_TERMINAL))
    canonical = set(csv_env("CRYSTAL_CANONICAL", DEFAULT_CANONICAL))
    aliases = {}
    for pair in csv_env("CRYSTAL_ALIASES"):
        if "=" in pair:
            k, v = pair.split("=", 1)
            aliases[k.strip()] = v.strip()

    # --pre-tool-use <file>: the PreToolUse gate. The payload is on stdin; the
    # state before the edit is the file on disk, the state after is what the
    # payload would leave there. Exit 1 with the findings on stderr when the
    # edit may not go through; any other non-zero exit is "no verdict".
    if "--pre-tool-use" in argv:
        i = argv.index("--pre-tool-use")
        path = argv[i + 1] if i + 1 < len(argv) else ""
        try:
            import json
            payload = json.loads(sys.stdin.read())
            tool_input = payload.get("tool_input") or {}
            after = _post_edit_content(payload.get("tool_name") or "", tool_input, path)
            if after is None:
                return 0
            before = _read(path)
            _, problems = blocking(path, before, after, canon, terminal, canonical, aliases)
        except Exception as exc:  # no verdict — the wrapper says NOT CHECKED
            sys.stderr.write("crystal-lint: %s: %s\n" % (type(exc).__name__, exc))
            return 3
        if problems:
            _report(path, problems)
            return 1
        return 0

    # --against <earlier> <file>: the same verdict for two files — <earlier> is
    # the state before (empty: the file is new), <file> the state after. The
    # pre-commit surface passes the blob at HEAD and the staged one.
    if "--against" in argv:
        i = argv.index("--against")
        earlier = argv[i + 1] if i + 1 < len(argv) else ""
        rest = [a for a in argv[:i] + argv[i + 2:] if not a.startswith("--")]
        if len(rest) != 1:
            return 2
        after = _read(rest[0])
        if after is None:
            return 0
        before = _read(earlier) if earlier else None
        _, problems = blocking(rest[0], before, after, canon, terminal, canonical, aliases)
        if problems:
            _report(rest[0], problems)
            return 1
        return 0

    quiet = "--quiet" in argv
    # --summary: one TSV row per file — `path <TAB> label <TAB> problem-count`.
    # Exists so other tools (crystal-cave) can ASK the linter instead of
    # re-deriving what "off canon" means. Same rule that makes check-doc-orphans
    # the single owner of the orphan contract: the algorithm lives in one place
    # and callers shell out to it.
    summary = "--summary" in argv
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        return 0

    failed = 0
    for path in files:
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            continue
        label, found = findings(path, text, canon, terminal, canonical, aliases)
        problems = [message for _, _, message in found]
        if summary:
            # `violations`: the structure is off, and the next edit owes it.
            # `log-debt`: only past entries and promises are — shown, owed by
            # no edit, because the log is append-only (canon-gate-scope DL #6).
            if label == "checked":
                if any(scope == STRUCTURE for scope, _, _ in found):
                    label = "violations"
                else:
                    label = "log-debt" if found else "ok"
            print("%s\t%s\t%d" % (path, label, len(problems)))
            if problems:
                failed += 1
            continue
        if label == "legacy":
            if not quiet:
                print(
                    "%s: legacy schema (`crystal-schema: legacy`) — NOT canon; "
                    "never infer a workitem's shape from this file" % path
                )
            continue
        if label in ("skipped-terminal", "skipped-artifact"):
            continue
        if problems:
            failed += 1
            _report(path, problems)
        elif not quiet:
            print("%s: ok" % path)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
