---
name: docs-distill
description: "Owns the SYNTHESIS layer — the summary view that has to be REBUILT rather than appended to. Invoke when: the drift signal fires (a synthesis document is older than what it covers); a crystal that produced outward artifacts is about to be cut; a project has feature docs but nothing that answers 'how is this put together as a whole'. Asks the question nobody asks: is what goes outward systematized, or is it ten unrelated documents from which no conclusion about commonality can be drawn?"
license: MIT
---

# docs-distill — the synthesis layer

## The law this skill exists for

**Fragments accumulate on their own. Synthesis does not.**

A decision log fills up by itself. `docs/features/` fills up by itself. But the
summary view — *how is this put together right now*, *are the approaches even
consistent*, *what breaks if I touch this* — is **never rebuilt, because nobody
asks.** Ten feature documents, each of which arrived correctly at its own
address, still support no conclusion about commonality. The synthesis gets
assembled in the reader's head, and evaporates there.

This is the same disease the crystal suite already treats one floor down:

| | Fragments (accumulate) | Synthesis (must be rebuilt) |
|---|---|---|
| Inside one task | `## Decision Log` | `## Текущая модель` |
| **Across the project** | `docs/features/*`, crystal findings | **this skill** |

**Append is not synthesis.** If you find yourself adding a paragraph to the
bottom of a synthesis document, stop — you are producing another fragment. The
document is rewritten to describe the current whole, or it is not synthesis.

## What this skill is NOT

**Not a router.** Routing findings to addresses (features / llm / changelog) is
a consequence, not the point. Ten findings can each reach the right address and
leave no synthesis behind. What is missing is not transport — it is
**reassembly**.

## The suite dictates the relation, not the artifact

What synthesis *is* differs per project: an event map, an architecture doc, a
domain model. **Never dictate the form.** The suite may only require that
synthesis (a) exists, (b) declares what it covers and what question it answers,
(c) has not fallen behind its inputs. What it synthesizes is the project's call.

## Discovery — the `covers:` contract

A synthesis document is any markdown file whose frontmatter declares `covers:`.
Not a fixed path (`docs/model/` would break every project that names the tier
after its domain — the field specimen chose `docs/analytics/`). Not `type:`
either — that is a human label with no mechanical role.

`covers:` is the contract **because it is the field drift is computed from**. A
document without it cannot be drift-checked at all, so it cannot participate.

```yaml
---
type: model                                    # human label, no mechanical role
question: "what a reader opens this file to get answered"   # the identity rule
covers:                                        # REQUIRED — discovery + drift input
  - docs/features/*.md
  - src/analytics/
observed: 2026-07-14                           # absolute date of last verification
---
```

The `question:` field is a field finding, not an invention: the projects that
built this tier on their own each opened it by **declaring the question**. A
synthesis is defined by the question it answers, not by the files it contains.
If the question cannot be stated, there is no synthesis — there is a pile.

**The scan is a script, not a checklist.** Never re-derive the algorithm:

```bash
Bash(command="bash ${CLAUDE_PLUGIN_ROOT}/scripts/distill-scan.sh --list", ...)   # every synthesis doc
Bash(command="bash ${CLAUDE_PLUGIN_ROOT}/scripts/distill-scan.sh --drift", ...)  # only the stale ones
```

Exit 0 always; empty stdout means nothing to report.

## When this fires

Three triggers, and **none of them is "before completing a task"** — that
instant belongs to `docs-sync`, and it is the wrong instant for synthesis
anyway: far too late to distill on the fly.

| Trigger | Source | What it means |
|---|---|---|
| **Drift signal** | `docs-distill-reminder` hook | A synthesis document is older than an input it declares it covers. Drift is a *state*, not a moment — it persists from the edit that caused it until the rebuild that clears it. |
| **Before cutting a work-phase crystal** | `crystal-cut` | The crystal produced artifacts that went outward. Its findings must be harvested before it closes. |
| **No tier at all** | this skill, on invocation | The project has fragments and nothing that reassembles them. |

## Protocol

### Phase 1 — Scan

Run `distill-scan.sh --list`. Two outcomes:

**Tier exists** → go to Phase 2 for each drifted document.

**No tier at all** → this is the bootstrap case, and it is the whole reason the
skill exists. In the field specimen the forcing function was a *human* who
finally asked "why are there no results written down anywhere". Be that
question. Do **not** create the tier silently — propose it:

1. Name the question the project needs answered (from its feature docs, its
   crystals, its code layout). If unclear, ask the user — the question is the
   document's identity and guessing it wrong produces a pile with a title.
2. Propose a location. **The project names it**, not the suite.
3. Copy `${CLAUDE_PLUGIN_ROOT}/templates/synthesis-template.md` and fill it in.

### Phase 2 — Rebuild (not append)

For each drifted document, the scan already named the inputs that outran it.

Read the newer inputs. Then **rewrite** the "how it works now" section to
describe the current whole. Ask, out loud, the question the tier exists for:

- Are these approaches actually consistent, or have they diverged?
- What conclusion about commonality can be drawn — and does the document say it?
- What breaks if someone touches this?

An edit that only bolts the new input onto the end has failed the phase.

**When drift fired but nothing substantive changed.** This happens and it is not
a malfunction: the signal is mtime-based, so a typo fix or a comment in a
covered file trips it. The honest response has three steps, and the shortcut is
forbidden:

1. **Read the newer input.** You do not know it changed nothing until you look.
2. Confirm the model is unaffected — say so out loud, naming what you checked.
3. **Re-stamp `observed:` with today's date.** That is a real edit recording a
   real re-verification, and it clears the drift as a side effect.

**The same-day case.** If `observed:` already says today, step 3 is a no-op: the
file does not change, so the signal does not clear. This is the *only* situation
in which `touch` is legitimate — as the closing act of a re-verification that
actually happened, never as a substitute for one. Say in your reply what you read
and what you concluded; that statement is the artifact the reader can check, and
it is what separates this from the forbidden case.

Otherwise: **never** `touch` the file, and never edit it cosmetically to silence
the signal. Both skip step 1 and leave `observed:` asserting a verification that
did not happen — turning the only date the reader can trust into a lie. A signal
you are allowed to dismiss without looking is not a signal.

### Phase 3 — Harvest the crystal (pull, never push)

When an active crystal exists, **pull** from it. The crystal gets no new
section — a second home for the same statement guarantees the two will diverge,
which is this very disease reproduced inside the workitem.

Read `## Текущая модель` and `## Decision Log`. For each claim, ask: **does this
outlive the task?**

- **Dies with the task** (which option we picked, what we tried) → leave it.
- **Outlives the task** (how the thing now works, what invariant now holds) →
  it belongs outside, at an address.

Write back **only obligations** — into the crystal's `## Next actions`:

```markdown
- [ ] <finding> → docs/features/<x>.md
- [ ] <finding> → docs/model/<y>.md (synthesis: rebuild §"how it works now")
```

That is all the skill writes into the crystal. From there **the existing
completion-guard enforces it** — a crystal cannot be cut while an unchecked box
remains. No new hook, no new gate. Soft until named; binding the moment it is.

### Phase 4 — Update `observed:`

Set `observed:` to today's **absolute date**. This is the weakest rung of the
decay ladder; use a better one when the system offers it (see below).

## The two handoffs with `docs-sync`

The skills know about each other by name. Both directions are real work, not
decoration.

**`docs-sync` → `docs-distill`** — a feature doc was written, some synthesis
declares it in `covers:`, so that synthesis is now stale by construction. Hand
off.

**`docs-distill` → `docs-sync`** — the more important direction, and the less
obvious one: **synthesis exposes missing fragments.** While rebuilding, you hit
a hole — a capability nothing documents. You cannot synthesize over emptiness.
Stop, run `/vdm:docs-sync` to write the fragment, then resume.

Treat a hole found this way as a finding, not an annoyance: it is the tier
earning its keep. A layer that only ever restated what was already written down
would not be worth its cost.

## Decay detectors — use the strongest one available

Do not present the weakest rung as the general rule.

| Rung | Detector | Cost of a miss |
|---|---|---|
| **Best** | Fingerprint/hash the external system exposes — matches ⇒ current, by proof | none; it is a fact, not a guess |
| **Middle** | Regenerable, diffable export — re-export and read `git diff` | you must remember to re-export |
| **Worst** | Observation date + a manual gesture (what `observed:` is) | it is a heuristic, and it lies quietly |

Most systems do not expose a fingerprint, so `observed:` is the fallback — but
when a system *does* offer one, wiring it in beats any reminder we could write.
And the corollary the field taught: **a new failure mode earns a new assertion
in a script, not a resolution to remember.**

## Laws of every long-lived document in this suite

Apply these when writing or rebuilding any synthesis:

1. **Current state first; history separate and optional.** A document that opens
   with "it used to be…" forces every reader to replay the whole chronology to
   reach the truth. History goes into its own section (or its own directory)
   marked as archaeology.
2. **Absolute dates only.** "Recently", "2 years ago", "last sprint" lie
   silently a year on, because nobody re-reads a document to re-anchor them.
3. **Identifiers live in exactly one place**; everything else references it. A
   copied ID rots silently — nobody re-checks it, precisely because it is
   "already written down".
4. **Call things by name, not by a volatile number.** "Tag 320" means nothing in
   a year.

## Configuration

`/vdm:docs-distill [subcommand]` — first word of the arguments. No match ⇒ run
the skill normally.

| Subcommand | Effect on `.claude/vdm-plugins.json` → `distill` |
|---|---|
| `off` / `disable` | `enabled = false` (hook silent) |
| `on` / `enable` | `enabled = true` |
| `smart` | `mode = "smart"` — fire on drift, throttled (default) |
| `proactive` | `mode = "proactive"` — fire on drift every prompt, no throttle |
| `silent` | `mode = "silent"` — never fire |
| `config` / `status` | Show the current section |
| `reset` | Remove the `distill` key |

Defaults when absent: `enabled: true`, `mode: "smart"`, `throttle: 1800`.
Optional `paths` (array of globs) restricts the scan to an explicit tier instead
of scanning the repo.

Patch rules: modify only the `distill` key, preserve every sibling verbatim; use
Write/Edit rather than `jq` (users may not have it); valid JSON, 2-space indent,
trailing newline. Config path detection follows the same rule as the rest of the
suite (`<project_root>/.claude/` else `.qwen/`).

## What failure looks like

- A synthesis document that grew a new paragraph per change and now reads as a
  changelog → you appended instead of rebuilding.
- A synthesis that lists its covered documents and adds nothing → the reader
  could have read the directory. State the conclusion about commonality, or
  admit there isn't one.
- A crystal closed with its findings still in `## Текущая модель` and nowhere
  else → the harvest never happened; the knowledge died with the task.
- A tier nobody declared `covers:` on → invisible to the signal, quietly rotting.
