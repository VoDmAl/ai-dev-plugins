#!/usr/bin/env python3
"""Compare the vendored frontmatter reader against PyYAML on real trees.

Dev-time only — PyYAML is the oracle here, never a dependency of the plugin.

    python3 yaml-oracle-check.py <repo> [<repo> ...]

Reports, per repository: frontmatters, refusals, values that differ from YAML,
and — the number that matters — differences on keys the plugin CONSUMES. Any
non-zero in the last column is a live defect, not a subset limitation.

Written for vdm-comms 0.4.1 (docs/tasks/vdm-comms-field-fixes, DL #4-#5):
the check that found `sent: false  # comment` being read as sent.
"""
import glob
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "plugins", "vdm-comms", "scripts"))
import comms_frontmatter as fm  # noqa: E402

CONSUMED = {"type", "date", "tracks", "series", "topics", "people", "absent", "attachments",
            "slug", "migrated_from", "counterparts", "cadence", "transcript", "draft", "sent"}


def norm(v):
    if isinstance(v, dict):
        return {str(k): norm(x) for k, x in v.items()}
    if isinstance(v, list):
        return [norm(x) for x in v]
    return None if v is None else str(v)


def is_timestamp_only(ours, ref):
    return isinstance(ours, str) and isinstance(ref, str) and ours.replace("T", " ").rstrip("Z") \
        .split("+")[0] == ref.split("+")[0]


def main(repos):
    rc = 0
    for repo in repos:
        n = refused = differ = consumed = 0
        for f in glob.glob(os.path.join(repo, "**", "*.md"), recursive=True):
            if "/.git/" in f or "/node_modules/" in f:
                continue
            try:
                fmt, _ = fm.split_frontmatter(open(f, encoding="utf-8").read())
            except Exception:  # noqa: BLE001
                continue
            if not fmt.strip():
                continue
            n += 1
            try:
                ref = norm(yaml.safe_load(fmt + "\n"))
            except Exception:  # noqa: BLE001
                ref = None
            try:
                ours = norm(fm.parse(fmt))
            except fm.FrontmatterError as exc:
                refused += 1
                if ref is not None:
                    print("  refused valid YAML: %s — %s" % (os.path.relpath(f, repo), exc))
                continue
            if not isinstance(ref, dict) or ours == ref:
                continue
            differ += 1
            for k in CONSUMED & (set(ref) | set(ours)):
                a, b = ours.get(k), ref.get(k)
                if a != b and not is_timestamp_only(a, b):
                    consumed += 1
                    print("  CONSUMED KEY DIFFERS: %s `%s` ours=%r yaml=%r"
                          % (os.path.relpath(f, repo), k, a, b))
        print("%-20s frontmatters %5d | refused %3d | differ from YAML %3d | on consumed keys %d"
              % (os.path.basename(repo.rstrip("/")), n, refused, differ, consumed))
        rc = rc or (1 if consumed else 0)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
