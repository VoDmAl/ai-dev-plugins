---
type: meeting
date: YYYY-MM-DD
series: null            # the series slug, or null for a one-off meeting
people: []              # who is expected
tracks: []
topics:
  - name: ""            # the subject as the counterpart would name it — no position, tactic or ball status: this string is the anchor and the record's heading
    track: null         # one of `tracks:`, or `tail: true`
    owner: ""           # who holds the topic on their side
    must: false
    pitch: true         # said aloud at the meeting: pitch.md lists this name in its `topics:`
---

# <Meeting> <date> — the owner's sheet

> For the owner only: the order, the owners, what to do when someone is missing, the warnings. Internal
> wording belongs here. What is said aloud is in [pitch](pitch.md); the reasoning and the branches in
> [prep](prep.md).

## If not everyone came

1. In the first minute — who is in the room.
2. A topic whose owner is absent is not taken: whoever answers for them is overruled by the owner later.
3. What is cut goes back to the queue at once.
4. The time freed goes to the next topics of owners who are present.

## If time runs short

The must topics go first and whole; the rest follow in order. A must topic that did not happen is a line of
its own in the record.

## Topic 1. <name>

> Track: <link> · owner: <who> · must / if time allows

What this topic is for at this meeting, and what we ask — the words for it are in the pitch. What we do not
claim; which branches are not settled.

## Not raised

<in one line, each with its reason>

## After the meeting

- [ ] The record — `index.md` beside this file, with the same `topics[].name`
- [ ] What did not happen goes back to the series queue
- [ ] What was decided goes to each track's notes, not as a copy of the record
- [ ] New commitments go where they are re-read when they fall due
