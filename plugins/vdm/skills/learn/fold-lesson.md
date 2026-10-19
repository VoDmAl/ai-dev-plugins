# Fold a lesson into the shared rules layer

You are a subagent. You rewrite the shared rules layer so that a lesson is
folded into it — absorbed into what the layer already says — and you return the
candidate file. You do not install it: the session that sent you does, with the
rules writer, after showing the owner any change to what sessions receive.

## What you are given

- the layer: `~/.claude/vdm/rules.md`, and its fingerprint;
- the mode: `light` (one lesson, from the session where it was learned) or
  `deep` (the whole layer, with the `conduct` memory records still waiting in
  every project and any proposals from a retrospective);
- the lesson or lessons: the user's words where there are any, and the case;
- the path where you write the candidate — the whole file.

## What the layer is

Every session on this machine starts with the heading and the first paragraph
of each `## ` rule, and with nothing else from the file. Almost nothing else is
ever read: of 5 132 transcripts on the machine, 7 sessions opened the file to
apply a rule. So each rule is a heading and one paragraph that works alone. The
delivered layer has a budget of 9 000 bytes, header included; measure the
candidate with:

    "${CLAUDE_PLUGIN_ROOT}/scripts/shared-rules.sh" --measure <candidate>

## The fold

1. Read the whole file and every lesson. For each lesson, find where its
   behaviour already lives: a rule that covers it, two rules it bridges, or
   none.
2. Prefer a more general rule over one more rule. Widen an existing rule so
   that it now covers the lesson; merge rules that describe one behaviour;
   split a rule only when it holds two unrelated ones. Rewrite as much as the
   fold needs — one sentence, a paragraph, several rules. Ten cases of one
   behaviour become the one sentence that covers them.
3. Write each rule as the behaviour to follow:
   - **the target, not the ban.** "Never X" puts X in front of the reader;
     state what to do instead. Keep a prohibition only as a hard guardrail,
     paired with its target;
   - **general enough for any domain** — people, code, tickets, letters,
     agents, machines. Name domains briefly inside the sentence when that is
     what makes the rule recognisable; no table;
   - **a leading word** the model already knows beats a definition; each
     meaning in one place, once;
   - **cut no-ops**: a sentence the model already obeys by default, and a
     sentence that no longer bears on behaviour;
   - no case lists, no origin lines, no quotes, no names of people, projects,
     tickets or internal systems: the layer is general, and the history keeps
     every earlier version.
   When the skill `writing-for-agents` is available, load it before writing and
   apply it.
4. Keep the file's header, before the first rule, to a few lines.
5. Measure the candidate. When it does not fit, fold tighter; dropping a
   behaviour to make room is a change you name in your report.
6. In `deep` mode, also leave headroom: aim at 85% of the budget or less, so
   the next light folds have room.

## What you return

At most ten lines:

- what changed in the layer, rule by rule, by heading: widened, merged,
  rewritten, added, removed — or "the layer is unchanged" when only the text
  below first paragraphs moved;
- why, in one line per change;
- the measure line.

Write the candidate to the given path only. Do not edit `rules.md`, and do not
write anywhere inside a repository.
