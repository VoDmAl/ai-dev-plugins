# vdm-comms

Meetings and correspondence discipline for a repository that keeps them as
files. One home for a tool three repositories had each copied and drifted.

## What it does

| Piece | Kind | When |
|-------|------|------|
| contract linter | `PostToolUse` hook + CLI | after any write into the meetings tree |
| outgoing-draft guard | `PreToolUse` hook | when creating `*/comms/*-out.md` |
| generated-layer drift signal | `SessionStart` hook | once per session, and only when something is behind |
| `/vdm-comms:meetings` | skill | the contract, configuration, onboarding |
| `/vdm-comms:index` | skill | rebuild the registry, series lists and track pointers |

## The model

```
meetings/
  INDEX.md                          generated registry (markers required)
  <series>.md                       type: meeting-series — body never checked
  <YYYY-MM-DD>-<slug>/
    prep.md  agenda.md  index.md    role files — under contract
    transcript.md, handout.md       raw material — left alone
<track>/comms/
  <date>-<slug>-out.md              a letter; `draft: true` until a person sends it
  <date>-<slug>-meeting.md          generated pointer back to a meeting
```

The contract is a **floor**: extra keys, extra sections and a project's own
file classes are never violations. Only what is missing or self-contradictory
is reported.

## Configuration

`.claude/vdm-plugins.json` → `comms`:

```json
{
  "comms": {
    "meetings-dir": "meetings",
    "track-roots": ["projects", "teams", "incidents"],
    "series": ["weekly", "steering"],
    "topic-sections": false,
    "labels": "en"
  }
}
```

Only what genuinely differed between the three field repositories is
configurable. `track-roots` is a list of allowed **first segments**, not a path
template: real track paths run one to three segments deep, some contain
capitals, and half of one repository's tracks resolve to `<path>.md` rather
than a directory.

`labels` is the wording of the files the generator writes **into your
repository** — `"en"` (default), `"ru"`, or an object overriding individual
keys (`{"col-meeting": "Созвон"}`), merged over English. It exists because a
table headed in the plugin author's language appearing in your document is the
plugin deciding something that was never its call.

## Dependencies

`python3`, standard library only. No PyYAML, no `jq` — the frontmatter reader
is vendored (`scripts/comms_frontmatter.py`) precisely so that installing this
plugin does not add the first third-party dependency to a project that has
none.

When a blocking hook cannot run it says `NOT CHECKED` and blocks, instead of
exiting quietly: "the check failed" and "the check did not run" are different
events, and only the first is what a clean exit means. The drift signal, being
a reminder rather than a gate, does the opposite and stays silent.

## Manual use

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh --all             # lint the tree
${CLAUDE_PLUGIN_ROOT}/scripts/comms-lint.sh --print-contract  # print the floor
${CLAUDE_PLUGIN_ROOT}/scripts/comms-index.py --check          # what is behind?
${CLAUDE_PLUGIN_ROOT}/scripts/comms-index.py --write          # rebuild, printing every path
```
