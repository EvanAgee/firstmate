# Move the offline Python runtime out of the workflow step function

The aos production deploy has failed since 2026-09-18 16:46 because one serverless function carries a
252MB payload it does not execute. Captain approved the blob move on 2026-09-18, after firstmate set
`VERCEL_SUPPORT_LARGE_FUNCTIONS=1` to unblock shipping in the meantime.

This spec is for an aos lane. It amends a signed decision and touches a security boundary, so it is
not a quick patch.

## The failure, measured

```
Error: The Vercel Function ".well-known/workflow/v1/step" is 252.14mb uncompressed
which exceeds the maximum uncompressed size limit of 250mb.
```

Three consecutive production deploys failed identically: runs 35370405799 (16:46), 35379944959
(18:23), 35384843678 (19:14). The last success was 35352764016 at 13:52 on `7efa7fdc8`. Six commits
landed between, none of which obviously adds 2MB; the bundle had been sitting just under the ceiling
and ordinary work tipped it over.

## What is actually in the 252MB

`next.config.ts` line 77 packs `sbsHardeningTracingIncludes` into the step route. Measured in the
clone on 2026-09-18, everything committed in that list is trivial:

| include | size |
| --- | --- |
| `sbs/memory/fixtures` | 16K |
| `sbs/schemas` | 28K |
| `sbs/runtime` | 32K |
| `harness/gates` | 20K |
| `sbs/gates` | 44K |
| `.aos-offline-runtime/**` | built during `vercel-build`, absent locally |

So the runtime is essentially the whole payload. `scripts/build-offline-runtime.ts` downloads the
wheels named in `sbs/runtime/runtime.lock.json` during the Vercel build, and the config packs the
result into the function.

## The real problem

A serverless function is being used as a delivery vehicle. The step function does not run that
Python; it carries it so it can hand it to a sandbox. Vercel's limit exists because functions are
meant to be code that executes. Raising the ceiling buys headroom without changing the trajectory.

## Why blob works, and why the offline guarantee survives

Decision 0268 requires the hardening stage to replay fixtures inside a Vercel Sandbox **with no
network**. That constraint is on the sandbox, not on the step function.

The step function has network access. It already talks to the sandbox to upload the runtime. So the
function can fetch the runtime from blob at request time and upload it into the sandbox exactly as it
does today from its own bundle. The sandbox never reaches the network. 0268's guarantee is intact.

## What must survive the move

0268 is not about where the bytes live. It is three promises, and all three must hold afterwards:

1. **The digest pin still gates every sandbox.** `src/lib/skills/offline-runtime.ts` pins the content
   digest and `locateOfflineRuntime()` returns a verified path or a named refusal. That verification
   must run against the bytes fetched from blob, before anything reaches a sandbox. A runtime with
   other bytes, another CPython, a missing declared extra, or a symlink must still be refused by name.
2. **The deploy still fails when the runtime is wrong.** Today `build-offline-runtime.ts` fails the
   build when what it produced does not match the pin. After the move, the deploy must refuse unless
   blob actually holds an object matching the pinned digest. Without this, a deploy can ship with a
   missing or stale runtime and only discover it when a user's skill build refuses at request time.
3. **No third-party bytes get committed.** 0268 rejected committing a megabyte-scale tree of Python so
   reviews stay readable. Blob respects that.

## The honest risk this introduces

Today the runtime cannot be absent, because it ships inside the function. With blob it can be absent,
stale, or deleted, and the failure moves from deploy time to request time. Criterion 2 above is the
mitigation and is not optional.

## Verify before building

**Can the sandbox upload path take a stream?** If it requires a local file, the function must buffer
252MB in memory or temp space, which has its own limits and may defeat the point. Answer this first;
if the answer is no, stop and report rather than building around it.

Also confirm whether blob is the right store for an object this size, and what it costs to fetch on
every hardening run. A per-run 252MB fetch has a latency and money cost that the current design does
not pay. If that cost is unacceptable, caching the runtime on the function's ephemeral disk across
warm invocations is the obvious follow-up, but measure before assuming.

## What already exists

`@vercel/blob` ^2.6.1 is a dependency. `BLOB_READ_WRITE_TOKEN` is set for production and preview, and
a kernel blob driver already selects Vercel when that token is present (`AOS_BLOB_DRIVER` overrides).
Reuse that driver rather than adding a second blob path.

## Acceptance criteria

1. The `.well-known/workflow/v1/step` function no longer includes `.aos-offline-runtime/**`, and its
   deployed size is reported before and after.
2. A production deploy succeeds with `VERCEL_SUPPORT_LARGE_FUNCTIONS` removed. Removing that flag is
   part of this work; leaving it set hides whether the fix worked.
3. The hardening stage still completes a real skill build end to end, with the sandbox offline.
4. The digest verification runs against the fetched bytes. Prove it: feed it a deliberately wrong
   runtime and show the named refusal, then restore.
5. The deploy fails when blob does not hold the pinned digest. Prove it with a deliberate mismatch.
6. `sbs/runtime/runtime.lock.json` remains the source of truth for which wheels are packaged.
7. Decision 0268 gets a dated amendment recording the new location and the new deploy gate. Do not
   edit the original in place.
8. `build-fixtures-tracing.test.ts`, which pins the tracing includes, is updated to match.

## Walked-path proof

Under `## What I walked`: the function size before and after, a real skill build completing through
the hardening stage with the sandbox offline, the wrong-runtime refusal by name, the deploy refusing
on a blob digest mismatch, and a production deploy succeeding without the large-functions flag.

## Constraints

- This is a security boundary. The digest check is what stops arbitrary Python reaching a sandbox.
  Never weaken or skip it to make the move simpler.
- Fail closed everywhere. A missing runtime, an unreachable blob, or a digest mismatch refuses the
  build with a named reason. It never falls back to an unverified runtime.
- Do not commit the wheels.
- One sentence per line in docs. Plain dash, never an em-dash. No agent co-author trailer.
- Commits authored as evanagee@gmail.com.

## Related

The large-functions flag was set on aos production 2026-09-18 as a temporary unblock. Criterion 2
removes it. Until this lands, production ships with a beta flag raising the function size ceiling.
