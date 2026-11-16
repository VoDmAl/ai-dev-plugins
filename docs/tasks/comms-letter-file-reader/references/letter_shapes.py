"""Where outgoing letters keep subject and recipients: frontmatter keys vs body lines.

    python3 -I letter_shapes.py "<root holding the projects>"

Counts, per project under <root>, the `*-out.md` files in a `comms/` directory that carry
`to:` / `person:` / `cc:` / `subject:` / `attachments:` / `channel:` in frontmatter, and a
subject or recipients line in the body (the regexes of comms-lint.py). Crystal
comms-letter-file-reader, Текущая модель; run 2026-11-03."""
import os, re, sys, collections
root = os.path.expanduser(sys.argv[1])
skip = {"node_modules", "vendor", ".git", ".stversions", "_import"}
per_repo = collections.defaultdict(collections.Counter)
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d not in skip]
    if "/comms" not in dp: continue
    for fn in fns:
        if not fn.endswith("-out.md"): continue
        p = os.path.join(dp, fn)
        try: t = open(p, encoding="utf-8").read()
        except Exception: continue
        repo = os.path.relpath(p, root).split(os.sep)[:1]
        repo = "/".join(repo)
        c = per_repo[repo]; c["files"] += 1
        fm = ""
        if t.startswith("---\n"):
            end = t.find("\n---", 4)
            if end > 0: fm = t[4:end]
        body = t[len(fm)+8:] if fm else t
        for k in ("to", "person", "cc", "subject", "attachments", "channel"):
            if re.search(r"(?m)^%s:" % k, fm): c["fm:" + k] += 1
        if re.search(r"(?m)^\*\*(Subject|Тема)\*\*:", body): c["body:subject"] += 1
        if re.search(r"(?mi)^\s*(>\s*)?\*\*(to|кому)(:\*\*|\*\*:)", body): c["body:recipients"] += 1
for repo, c in sorted(per_repo.items(), key=lambda x: -x[1]["files"]):
    print(repo, dict(c))
