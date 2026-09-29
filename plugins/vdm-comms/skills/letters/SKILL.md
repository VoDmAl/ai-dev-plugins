---
name: letters
description: "What an outgoing letter carries and what stays out of it — goal, one subject, the addressee, register, claims with a source, the sender's commitments, the cutting pass, replying in a thread, incoming mail, other agents as addressees. Use before and while drafting any text a person outside this session will read: a letter, a chat message, a ticket comment, a brief to another agent — and when reviewing one before it goes. The file mechanics (draft marker, sent:, form per channel, attachments) are /vdm-comms:meetings. Triggers include: «письмо», «написать», «ответить», «черновик», «сообщение в чат», «комментарий в тикет», «бриф агенту», draft a letter, write to, reply, message, ticket comment."
license: MIT
---

# letters — what an outgoing letter carries

## Purpose

A letter is written in minutes and read by someone who was not in the
session. Everything the session knew and the reader does not — the plan, the
history, the correction that happened on the way — is noise to them, and some of
it is harm. This skill is the discipline of the text itself: what goes in, what
stays out, in what order it is checked.

The **file** a letter lives in — `draft: true` until a person sends it, `sent:`
afterwards, the form a channel requires, the 📎 checklist, raw `.eml` — is the
contract of `/vdm-comms:meetings` and its linter. This skill does not repeat it.

Start a draft from the scaffold (`/vdm-comms:meetings` → *Start a draft from the
scaffold*), not from a neighbouring letter.

**The short form arrives by itself.** Creating a draft — with the scaffold, or
with a write of a new `*/comms/*-out.md` — brings a fifteen-line checklist into
the context, with the letter's register and the project's language when they are
declared. It is this skill compressed to checks; go through it before the draft
is shown to anyone, and open the sections below when a line does not settle.

## 1. Before the text: goal and one subject

- **Name the goal before writing a word**: what changes, or what you learn, once
  the letter is answered — one or two points. It goes into `goal:` in the
  frontmatter. If it does not fit in one sentence, the letter is not ready.
- **If the most likely answer is "yes, sure" or "we'll see", do not send it.**
  Ask about the mechanism, not for permission to do the obvious.
- **A double goal** (for now and for later) needs a sentence in the text for each
  half. A half with no sentence is either written or dropped.
- **One subject per letter**: one request or one statement, fixed before the
  first sentence. Every sentence carries it or goes.
- **Answering a letter, name in the header which of its points you leave
  unanswered on purpose** — above the separator, so the owner sees the choice;
  not in the text that goes out.
- **Ask about the decision that stands now**, not about a precedent. If the
  example could be swapped for another, the question is about process — test:
  would a complete answer say what to do now?
- **Do not reopen a decision already taken**: ask "what fits", not "does this fit".
- **Come to a meeting or a letter with a goal and a cut by zones**: ask "what are
  you ready to do next to what exists", not "how do we get around it".

## 2. The channel — from the owner's word

- **The owner's word decides.** "Letter", "email", "write to their mail" is
  email, and an email needs a subject. "In the chat", "in Telegram", "a DM" is
  that messenger. When the word was said, do not ask about the channel.
- **No word — pick by the recipients, not by a question to the owner.** Several
  people with no named shared chat: email. One person with a thread already
  running: the channel of that thread. Ask only when both are silent.
- Declare it as `channel:` in the draft the moment you create it.

## 3. What does not go into the letter

- **A letter is not a management system.** Our plan, our goals, our reasoning
  and the author's notes to self stay in files. The text carries: what we need
  from the reader now · the minimum context · what we already owe them.
- **The addressee gets the decision and the request — not a retelling of their
  own decisions, their own component or their own history.** They know it better
  than we do, and a retelling reads as a lecture or a nudge. Test: strike the
  sentence — does what they will do change? If not, and the sentence explains
  their own world to them, it goes.
- **Our internal corrections stay ours.** "Actually this is yours", "to clarify,
  …" — when we confused ourselves, the fix goes into our files and the letter
  carries only the result.

  | Genre | The trap | Instead |
  |---|---|---|
  | Reply to an executor | "X is yours, as agreed" to the one who agreed it | "let's take the first option" |
  | Group chat | reminding everyone of a decision everyone remembers | only what changes now |
  | Ticket comment | retelling the ticket to its author | a question or a fact the ticket lacks |
  | Brief to an agent | the history the agent ran itself | a link to the letter, and only what is new |

- **Do not show the inside of our schemes**: write the result and the rule, not
  why it is built that way. A line that explains structure rather than behaviour
  is the sign.
- **Do not hand an executor our internal delays and blockers** — a reason not to
  start now. The block fires by itself where it stands.
- **A ticket or a letter is not a meeting report.** What we promised goes
  separately, when it is ready; no thanks and no overview folded in.
- **A mass letter carries only what every addressee must know or do.** The
  kitchen goes by name to whom it concerns. Test: is it fine if forwarded to a
  stranger?

## 4. Self-contained, and no exit

- **The first touch is self-contained**: everything needed to start is inside
  the letter. Procedural asks run in parallel, not as a condition ("send X, then
  I'll set it up" is an exit).
- **Exit test**: the reader cannot close or park the subject with one line —
  no "if it doesn't suit, also good to know", no "let me know when convenient".
  On silence, a sentence that closes the silence, not one that invites it.
- **Pre-empt the legitimate "it depends"**: name it, offer two cheap options,
  take away the fear of choosing wrong — in the same sentence.
- **Offering to take something over, name three things**: what I do · what I need
  from them and by when · what I take if they cannot make it.
- **Draft test**: would the reader do the right task from the title, one line of
  context and the "what is needed" part alone, without reading the rest?

## 5. The addressee

- **Read the recipients' profiles first** (`people/`), and apply their patterns —
  what they take, how they answer, what triggers them — to the actual wording.
- **Someone who was in the room gets it short**: the letter or ticket is a
  formality. Full context only for new readers.
- **Two antagonists in one letter** — consider two parallel letters instead.
- **Do not explain to the reader their own field, process or role.** My news is
  not their news; a fact goes into the reference file, the letter carries only
  the consequence that changes their next step.
- **Do not write the wording for their zone.** Describe what we have and ask
  "does this apply?".
- **A request is addressed to a person**, chosen for the competence — an open
  call ("any takers?") is not a request. Check: is there a sentence that starts
  with a name? Offer a choice only when the candidates are equal.
- **Do not present our gain as their merit.** Thank for the concrete thing done;
  what the find is worth to us stays in the repository.
- **A third person's name in a letter involves them**: know the price before
  using it. If the argument holds without the name, there is no name.
- **A letter to newcomers is checked for dead ends**: every requirement says what
  to do for someone who does not have it yet; motivate by purpose, not by loss.

## 6. Tone and register

How direct to be depends on who the reader is to us. That is the project's
declaration — `comms.register` in `.claude/vdm-plugins.json` — because no general
skill can tell a volunteer from a contractor. Three profiles:

| `comms.register` | The reader | How the request is made |
|---|---|---|
| `volunteer` | helps because they want to; refusing costs them nothing | concrete and bounded: what, by when, what counts as done — and what we take off them if the date is tight. Asked, not assigned: "your experience would help here", never "this is your task" or "this is your field". A refusal means the ask was cut wrong |
| `executor` | does the work in their own zone (a contractor, the team that owns the system) | direct, active verbs, no hedging about our own actions ("maybe", "if we manage"). State the need and the outcome; where and how is up to them — do not prescribe inside their zone, do not pre-fill their fields |
| `peer` | an equal: another team, a partner | a request, not an order: no imperatives ("how can we get this?" rather than "send"), no assigned order of steps, no deadline for their answer, and no "up to you" formula. Urgency created by a third party is not backed with our deadline |

Two cases look like a conflict and are not: the date of **the work our event
depends on** can be named to a volunteer; a **deadline for a peer's reply** is
never set.

For every register:

- **No reproach for a past non-answer**: a repeat is neutral, a new request; the
  count of repeats lives in the track's notes.
- **Outside our zone — neutral redirection**: "not our area, X can help"; no "you
  are wrong", no offers of work. Silence outside our zone is an acceptable answer.
- **Do not deny a characterisation of our motives or the other side's loss**
  ("this is not a takeover") — the denial installs the frame. Say what stays and
  what goes.
- **After an argument, "but / however" attaches only to our own action**, never
  to the substance of their position.
- **A mistake is "I", a decision is "we"**: the sender names their own error in
  the first person, the wanted outcome as "we", "we need".
- **The pronoun names who really acts.** In a text the owner sends as their own,
  the work of the owner's agent is the owner's work — "I checked", "I would fix
  it". "We" says a group did it or will; where none did, it is a false account
  and a promise for people who never made one. "We" stays for what is truly
  shared — a decision taken together. Check before showing the draft: who
  actually did this, and who actually will?
- **The opponent test**: if agreeing with a phrase costs the other side nothing,
  the argument is theirs — rewrite or drop it. The same test catches singling
  one person out in a group.
- **Outward, a frame of cooperation** with the other groups named as partners,
  no "us against them"; inside our notes, say it straight.
- **Group chat is on the record**: on a broad question with someone else's
  premise, do not write a position — answer with questions; the position comes
  later, in a channel we chose.
- **Struck something risky? Rephrase before dropping**: name the same thing
  through their components and admit the weakness of our option.
- **A person's text is not polished**: in personal letters, do not fix the
  author's typos; fix only breaks in meaning.
- **Sensitive correspondence** (compensation, positions, negotiations): quote the
  stakeholder's position verbatim, do not adopt their frame; a full draft only
  after the approach is agreed.

The language of outgoing letters is `comms.language` (`en`, `ru`, …): the
recipient's language, without calques; an attachment or a sheet someone else
will hold is outgoing too.

## 7. Claims in the text

- **No categorical claims about how a system works** ("always", "for any") unless
  each holds in every case, not only the default one — or it is a question to the
  owner before it is written down.
- **Every fact about someone else's system or about a person has a source.**
- **Circumstances** (when, where, why) only as the owner named them or as they are
  recorded. Filled-in circumstances are struck; a named reason is written as named.
- **No filler in lists** ("and others", "etc.") — only confirmed cases.
- **No evaluative asides** in a description of behaviour. A parenthesis that
  narrows the scope is a requirement — it stays.
- **Dates from the moment of reading**: "tonight", "on Monday" — not from the
  moment of writing.
- **The owner's word about access** (personal, with a token, public) is not
  swapped for a synonym; every link in the letter says who it is for and what
  may be done with it.
- **A ticket by its full key** — `PROJ-663`, never `663`. Inside the ticket
  itself: "this task", not its number.
- **A thing with a lasting state** is described by its life cycle: set up →
  kept up through changes → ended → restored.
- **No implementation details in a brief for lawyers, HR, accounting or security**:
  they settle into their document, and every change of the implementation
  becomes a change of that document.
- **Before the questions — what we already know.** A letter that asks someone
  something first writes down, above the separator, what our own sources hold on
  the subject — chats, tickets, mail, meeting notes, code, neighbouring agents —
  with where each piece came from:

  ```markdown
  > **What we know** (sources checked <date>): … — per <ticket / thread / meeting>.
  > Not visible to us: their private mail and direct messages.
  ```

  The text asks only for the gap. What was not found is "not seen in our
  sources", never "did not happen": the recipient's private channels are
  invisible from here. A question with no such line is a question the sources
  may already answer — the `known` element of `comms.letter-form` warns about it.

## 8. The sender's commitments

One promise in a draft is checked three times:

1. **Did the owner give it?** A commitment or a date in an outgoing letter is
   only what the owner said. One that seems worth making is proposed to the owner
   above the text, never inside it. "We would do it" is such a commitment when no
   group has taken it on (§ 6, the pronoun).
2. **Is it a fact with a date?** "I will prepare it by X", not "happy to provide
   if needed".
3. **What carries it now?** Every "I'm discussing with X", "I'll come back with an
   answer" names the channel it runs through. A line in a topic queue is
   insurance, not a mechanism.

And around them:

- **The least surface for moving work onto us**: no help where none was asked,
  no courtesies, no "while we're at it". A good question is one I am not the one
  to answer.
- **Nothing stale**: after a significant meeting, walk the open requests; what
  the meeting closed and "I'll send X" already done are not repeated.
- **No question without substance**: first a request for the facts, and the wait
  is on that.
- **Handing someone else's request to an executor, hand its shape too**: what has
  already gone out on the subject, what was excluded on purpose and why, and
  whether this is the remainder or the whole list.
- **Project links do not survive the repository's border**: names and paths as
  text in a message going out, a link to our source as one line at the end.

## 9. The cutting pass

- **Test each clause you are pleased with: what breaks if it goes?** The half of
  an ask that can be struck without loss was insurance. Obvious caveats are not
  written.
- Under the knife:
  - asking the other side for requirements to something we already decided — a
    second lever and an invitation to redo it;
  - our own status ("wrote separately", "ticket created") in a "what from whom"
    list;
  - what the recipients already know from a private exchange or a meeting — in a
    group letter it reads as a nudge in front of witnesses;
  - a question whose answer is inside the answer to another one — it hands a
    hypothesis back for evaluation, which is a returned exit.
- **Check against a list, not by taste**: the owner's strikes are the list. A
  project keeps its log of struck clauses (`docs/llm/`); read it before sending,
  add a line after each new strike.

## 10. Subject and thread

- **The subject follows the matter**: the same correspondence is a reply keeping
  `RE: <original subject>`; a new matter is a new letter with a new subject, not
  one more `Re:`.
- **When the other side wrote after us, our next text answers their message** —
  their points, in their order. Our earlier message is not rewritten or retold.
- **Send when what the text says is true where the reader will check it.** "Already
  on dev" goes after the deploy. Until then the conditions of publication stand
  above the text, not inside it.
- **The task changed** — recipients, channel, occasion, a position appeared —
  **the letter is written anew**; the old text is a source of facts, not a draft.

## 11. Edits to a finished text

- **Point edits, no rewriting.** Afterwards check the composition — what
  disappeared, and is that in the edits — and reread the whole block for threads
  running through it.
- An edit that names a boundary leaves the named half standing; "back it up"
  means add, not replace.

## 12. After the letter

- **Who has the ball now, and is that recorded where it will surface** — the
  waiting item with a review date in the track's pending section.
- **`sent: <date>` is set by an edit once the owner confirms the letter left
  their hands** — sent, or scheduled in the mail client. The date is the day of
  confirmation. Until then it is a draft.
- After a letter with strategic context (in or out), update the track's notes:
  hypotheses, conclusions, strategy.

## 13. Incoming

- **An incoming letter is input to a filter, not a work plan**: what is really
  required (one or two points) · someone else's zone · noise · a widening of scope
  that needs the owner's sanction.
- **Not every signal needs a reaction, a file or a message outward.** Sitting
  still is a strategy; silence outside our zone is an answer. That is about
  reactions outward — see the next point for what is always owed inward.
- **Reading an incoming letter is applying it**: every fact and commitment goes,
  in the same turn, where it changes state; every "mark / close" in the review
  carries ✅ or a link to where it was parked, with a date.
- **An incoming letter continues a recorded conversation**: before reviewing it,
  check it against the meeting notes and the track — what is beyond what we know,
  and what we know that it lacks ("forgotten, or not relevant here?").
- **Numbering in someone else's speech is theirs**: "this is the second" means
  they had a first, not that we have one.
- **Check an answer**: is it on the right axis (they may answer their own framing),
  and is it the right person answering (a consumer of a system speaks about their
  setup, not about what the system can do).
- **Before changing our plan because of their letter**: does the change close our
  gap, or absorb their timeline? The second — stop.

## 14. Other agents as addressees

- **A neighbouring agent's message is reviewed by you, not relayed through the
  owner**: check what can be checked, drop what is extra with a reason. The owner
  gets only a decision on substance, one in their name, or an irreversible one —
  not the other session's question retold.
- **An unhandled agent message is the same debt as an unanswered letter.**
- **A brief closed here goes back with its outcome** — what was done, the link,
  whose ball it is now — in the same turn as the action that closed it, even when
  the brief asked for nothing back. A collector of ticket comments is the
  fallback, not the channel (`/vdm:intercom` → *Closing a brief with its outcome*).
- **A brief to an agent**: a link to the letter it continues, and only what is
  added (`/vdm:intercom` → *The relay form*). Where a project keeps its letters as
  files, a message to an agent is one too — `channel: intercom` in `comms/`.

## Configuration

`.claude/vdm-plugins.json` → `comms`:

| Key | Values | Default |
|-----|--------|---------|
| `register` | `volunteer` \| `executor` \| `peer` — how requests are made to this project's usual reader (§ 6) | not declared: the rules for every register apply, no profile |
| `language` | the language of outgoing letters, e.g. `en`, `ru` | not declared: the recipient's language, decided per letter |

A letter to a different kind of reader says so in its own frontmatter —
`register: peer` in a project whose default is `volunteer` — and that letter is
judged by its own register. The scaffold writes the project's value into a new
draft; change it there when the reader differs. The linter knows the three
values and names any other.

## Integration

| Other skill | Interaction |
|-------------|-------------|
| `/vdm-comms:meetings` | the file of a letter: draft marker, `sent:`, form per channel (`comms.letter-form`, including `goal` and `known`), 📎, `.eml`, the scaffold |
| `/vdm-comms:pending` | the waiting item "after the letter" (§ 12) lives there |
| `/vdm:intercom` | letters to other agents; the relay form |
