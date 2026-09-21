---
name: relay-reference
description: Load when activating Relay or handling a public commitment.
user-invocable: false
metadata:
  internal: true
---

# 14. Relay

For every Relay-linked terminal outcome, load that owner and use the promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up before teardown.

A promised final public reply is durable state, never conversation memory.
Load `fmx-respond` before promising one, on a `public-followup ...` check wake, and whenever the session-start digest lists a public commitment awaiting delivery or an open public loop.
Only the home holding the relay consent and thread binding ever posts it, so never ask a secondmate or crewmate to find the thread or send the reply, and never recover a terminal result by reading a `done:` sentence.
