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

Exit: 0 = clean, 1 = violations found, 2 = usage error.
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


def lint(path, text, canon, terminal, canonical, aliases):
    """Return (status_label, [problem strings])."""
    fm, body = split_frontmatter(text)
    problems = []
    named_workitem = declares_itself_a_workitem(path)

    if not fm:
        if not named_workitem:
            return "skipped-artifact", []
        return "checked", ["no YAML frontmatter — not a workitem shape at all"]

    raw_status = frontmatter_value(fm, "status")
    if raw_status is None:
        if not named_workitem:
            return "skipped-artifact", []
        return "checked", ["frontmatter has no `status:` key"]
    status = aliases.get(raw_status, raw_status)

    if status in terminal:
        return "skipped-terminal", []

    if frontmatter_value(fm, "crystal-schema") == "legacy":
        return "legacy", []

    if status not in canonical:
        problems.append(
            "`status: %s` is not in the canonical taxonomy (%s)"
            % (raw_status, ", ".join(sorted(canonical)))
        )

    # --- frontmatter keys (floor: missing only) -----------------------------
    present_keys = frontmatter_keys(fm)
    missing_keys = [k for k in canon["fm_keys"] if k not in present_keys]
    if missing_keys:
        problems.append("frontmatter missing: %s" % ", ".join(missing_keys))

    # --- sections (floor: missing only) -------------------------------------
    present = [text_ for text_, _ in headings(body)]
    missing = [s for s in canon["sections"] if s not in present]
    if missing:
        problems.append(
            "missing required section(s): %s"
            % ", ".join("## " + s for s in missing)
        )

    # --- Decision Log entries ------------------------------------------------
    if "Decision Log" in present:
        entries = dl_entries(body)
        if not entries:
            problems.append("`## Decision Log` present but contains no `### #N / …` entries")
        for lineno, heading, entry_body in entries:
            label = heading.strip()
            if not DL_HEAD_STRICT_RE.match(heading):
                problems.append(
                    "DL entry heading is not `### #N / YYYY-MM-DD / title`: %r" % label
                )
                continue
            fields = {}
            for line in entry_body:
                m = FIELD_RE.match(line)
                if m:
                    fields[m.group(1).strip()] = m.group(2).strip()
            absent = [f for f in canon["dl_fields"] if f not in fields]
            if absent:
                problems.append(
                    "DL entry %s missing field(s): %s"
                    % (label.replace("### ", ""), ", ".join(absent))
                )
            basis = fields.get("Basis")
            allowed = canon["basis_values"]
            if basis and allowed and basis not in allowed:
                problems.append(
                    "DL entry %s has `Basis: %s` — allowed: %s"
                    % (label.replace("### ", ""), basis, ", ".join(allowed))
                )

    return "checked", problems


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

    quiet = "--quiet" in argv
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
        label, problems = lint(path, text, canon, terminal, canonical, aliases)
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
            sys.stderr.write("%s\n" % path)
            for p in problems:
                sys.stderr.write("  ✗ %s\n" % p)
        elif not quiet:
            print("%s: ok" % path)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
