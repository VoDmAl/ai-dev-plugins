---
intercom: v1
from: {{FROM}}
from_agent: "{{FROM_AGENT}}"
to: {{TO}}
to_input: "{{TO_INPUT}}"
created: {{CREATED}}
slug: {{SLUG}}
status: pending
---

> 📤 **FROM:** `{{FROM}}`{{FROM_AGENT_SUFFIX}}
> 📥 **TO:** `{{TO}}`
> **Action:** review → `/vdm:intercom pickup {{SLUG}}` (archive to `_done/`) — or `pickup {{SLUG}} --grow` to promote into a workitem, then implement + commit **there**.

# {{TITLE}}

<!-- Write the brief below. Replace this comment with the actual message body:
     what to do, why it matters, acceptance criteria, and any reference paths.
     The envelope above is the machine-readable truth (who → whom); this banner
     is rendered from it. Do not hand-edit `from`/`to` — they are resolved. -->
