# Walkthrough: Building a Policy-Grounded Compliance Agent

A step-by-step account of how this system is built and why each piece is shaped the way it is.
Every output shown below is real, captured from an actual run.

If you only want to *run* it, the [README](../README.md) has the short version. This document is
for understanding it — or rebuilding something like it.

**Contents**

1. [The problem](#1-the-problem)
2. [The core idea](#2-the-core-idea-make-the-model-show-its-work)
3. [Writing policies an LLM can cite](#3-writing-policies-an-llm-can-cite)
4. [Indexing: text to searchable vectors](#4-indexing-text-to-searchable-vectors)
5. [Retrieval: finding the right clauses](#5-retrieval-finding-the-right-clauses)
6. [Drafting: constraining the model](#6-drafting-constraining-the-model)
7. [Validation: the deterministic gate](#7-validation-the-deterministic-gate)
8. [Seeing it work](#8-seeing-it-work-end-to-end)
9. [Things that went wrong](#9-things-that-went-wrong)
10. [What I'd do differently at scale](#10-what-id-do-differently-at-scale)

---

## 1. The problem

An HR event happens — someone is terminated, requests leave, changes status. Company policy says
certain things must happen by certain dates. Miss one and you have a compliance problem.

The obvious idea is to ask an LLM: *"here's the event, here's the policy, what do we do?"* That
works right up until it doesn't, and the failures are quiet:

| Failure | What it looks like |
|---|---|
| Invented obligations | Confident, plausible actions that no policy requires |
| Bad arithmetic | Correct rule, correct offset, wrong date |
| Stale knowledge | Answers from training data instead of *your* policy |
| No audit trail | "The AI said so" is not a defensible answer to a regulator |

Each one produces output that *looks* correct. That's the part that matters — a loud failure is
an inconvenience, a quiet one is an incident.

---

## 2. The core idea: make the model show its work

Split the system in half:

- **AI proposes.** Retrieve the relevant policy text, have the model draft a structured plan, and
  require it to cite the clause behind every single action.
- **Deterministic code disposes.** Validate that plan against a hard schema, independently
  recompute every date, and only then execute.

The consequence worth stating plainly: **the AI half cannot cause an incorrect action to
execute.** The worst it can do is produce a plan that gets rejected — which is logged and
visible, not silent.

Two design choices carry most of the weight.

**Every action must carry a verbatim `sourceClause`.** Not a summary — the actual text. If the
model can't point at a clause, it doesn't get to propose the action.

**Every action must carry both the offset and the computed date.** The model reports
`deadlineRuleDays` (the number it read from the policy) *and* `deadline` (the date it computed).
Those are independently checkable against each other:

```
deadline == effectiveDate + deadlineRuleDays
```

A model that only returned `deadline` gives you nothing to verify against. Requiring both turns
an opaque answer into a checkable claim.

---

## 3. Writing policies an LLM can cite

The corpus is three markdown documents. How they're *written* determines whether the rest works.

Each obligation is a numbered, self-contained clause with an explicit day offset:

```markdown
## 4. Benefits continuation

> **Clause 4.1** — A written notice describing the employee's options for continuing health
> coverage must be sent within 14 days of the termination date.

Action: `send_continuation_notice`
```

Three things are deliberate:

1. **The deadline is stated as a number of days**, not "promptly" or "as soon as practicable."
   The model has to extract `14`. Vague language gives it nothing to extract.
2. **The clause is self-contained.** It survives being pulled out of context by a chunker — it
   still makes sense alone.
3. **The action type is named in the document.** This closes the gap between prose and the
   `actionType` enum the schema enforces.

Some clauses are province-specific, which later gives us a clean way to prove retrieval is real:

```markdown
> **Clause 3.2** — In Quebec, all accrued and unused vacation pay must be included in the final
> paycheque and paid within 7 days of the last day of employment.

> **Clause 3.3** — In Ontario, outstanding wages including accrued vacation pay must be paid by
> the later of 7 days after employment ends or the employee's next regular pay date.
```

---

## 4. Indexing: text to searchable vectors

Run once, and again after any policy edit.

```
Manual Trigger ─┐
                ├─► Read Files ─► Extract Text ─► Prepare Docs ─► Vector Store [insert]
Webhook ────────┘                                                      ▲          ▲
                                                          Gemini embeddings   Data Loader
                                                                                   ▲
                                                                          Text Splitter
```

### Chunking

1000 characters with 200 characters of overlap. The overlap matters more than it looks: without
it a chunk can end mid-clause — *"...must be sent within"* — and the offset is lost. Overlap
means every clause appears whole in at least one chunk.

### Metadata is the citation

Each chunk carries the filename it came from:

```json
{ "name": "sourceDocument", "value": "={{ $json.docName }}" }
```

This is the thread that makes auditing possible. The filename travels from disk → chunk →
prompt → the model's answer → the validated plan. Break it anywhere and citations become
unverifiable.

### The result

```
total chunks inserted: 11
   termination.md          -> 4 chunks
   benefits-eligibility.md -> 4 chunks
   leave-policy.md         -> 3 chunks
chunks MISSING sourceDocument: 0   (every chunk is citable)
```

That last line is the one to check. A chunk without metadata is a chunk the model can retrieve
but not cite.

---

## 5. Retrieval: finding the right clauses

An incoming event:

```json
{
  "eventType": "termination",
  "employeeId": "EMP-1023",
  "effectiveDate": "2026-09-30",
  "province": "QC",
  "metadata": { "reason": "voluntary", "department": "engineering" }
}
```

becomes a query string:

```
termination reason voluntary department engineering province QC — required actions, notices, deadlines
```

**Putting the province in the query is doing real work**, and it's measurable. Run the same event
type with `province: "QC"` and `province: "ON"` and compare the clause each cites for
`issue_final_paycheck`:

| Province | Clause cited |
|---|---|
| `QC` | *"In Quebec, all accrued and unused vacation pay must be included in the final paycheque and paid within 7 days…"* |
| `ON` | *"In Ontario, outstanding wages including accrued vacation pay must be paid by the later of 7 days after employment ends…"* |

Different text, from the same document, driven purely by the query. That's retrieval selecting
the right clause — not the model recalling employment law from training.

**This is the test worth building for any RAG system:** find two inputs that *should* retrieve
different things, and confirm they do. Without it you cannot distinguish working retrieval from
a model that happens to know the answer.

### One non-obvious wiring detail

The vector store emits **one item per retrieved chunk**. Feed that straight into the LLM and it
runs once per chunk — three chunks, three model calls, three competing answers.

A small code node collapses them into a single item first:

```js
const docs = $input.all().map((item) => item.json.document ?? item.json);
const excerpts = docs.map((doc, i) =>
  `[Excerpt ${i + 1}] sourceDocument: ${doc.metadata?.sourceDocument}\n${doc.pageContent}`
).join('\n\n');
```

It looks like plumbing. Remove it and you triple your API bill and get incoherent output.

---

## 6. Drafting: constraining the model

The prompt gives the model the event, the retrieved excerpts, and rules:

```
- Use ONLY the excerpts above. Do not apply outside knowledge of employment law.
- Every action must quote the clause it rests on verbatim in sourceClause, and name the
  sourceDocument it came from exactly as given above.
- If the excerpts do not clearly cover this event, return an empty actions array.
  Returning nothing is correct; inventing an action is not.
- deadlineRuleDays is the day offset stated in the clause. Set deadline to exactly
  2026-09-30 plus that many days.
- When a clause is province-specific, use the one matching the event province.
```

The third rule earns its place. Without an explicit instruction that *returning nothing is a
valid answer*, models reach for something plausible. Saying so directly is what makes silence an
option.

The output is constrained by a JSON schema attached to the chain, so the model is shaped at
generation time rather than corrected afterward:

```json
{
  "actionType": { "enum": ["send_continuation_notice", "end_benefits", "..."] },
  "deadline": { "type": "string" },
  "deadlineRuleDays": { "type": "integer" },
  "sourceClause": { "type": "string" },
  "sourceDocument": { "enum": ["termination.md", "leave-policy.md", "benefits-eligibility.md"] },
  "confidence": { "type": "number" }
}
```

**A schema is not validation.** It constrains *shape*. It cannot check that
`2026-09-30 + 14 days` really is `2026-10-14`, or that the quoted clause exists in the cited
file. That's the next stage's job.

---

## 7. Validation: the deterministic gate

A Spring Boot service at `POST /api/action-plans`. Four stages, in order.

### Stage 1 — Schema

The *same* JSON Schema the model was given, re-applied on receipt. Not redundant: the model is
constrained by it, but the request arrives over HTTP and nothing guarantees it came from that
model.

### Stage 2 — Semantics

The checks a schema structurally cannot express:

```java
LocalDate expected = effectiveDate.plusDays(ruleDays);

if (deadline.isBefore(effectiveDate)) {
    errors.add("%s.deadline: %s is before effectiveDate %s (a %d-day rule gives %s)"
            .formatted(path, deadline, effectiveDate, ruleDays, expected));
} else if (!deadline.equals(expected)) {
    errors.add("%s.deadline: %s does not equal effectiveDate %s + %d days (expected %s)"
            .formatted(path, deadline, effectiveDate, ruleDays, expected));
}
```

Errors accumulate into a list rather than throwing on the first one, so a single round trip
surfaces every problem.

### Stage 3 — Confidence routing

`confidence >= 0.7` executes. Below that, the action is **valid but queued for human review**.
Not an error — a routing decision. Uncertainty should slow an action down, not fail it.

### Stage 4 — Execute

Simulated here (it logs what it *would* do) and returns a receipt.

### Why a separate service

The same logic could live in a workflow node. Keeping it in its own service means it's testable
with `curl` alone — no LLM, no embeddings, no orchestrator. You can hand someone
`ActionPlanValidator.java` and they can see exactly what the system will and won't permit. That
argument is much harder to make about logic buried in a workflow.

---

## 8. Seeing it work end to end

### A valid plan

```bash
curl -X POST http://localhost:5678/webhook/hr-event \
  -H 'Content-Type: application/json' -d @sample-events/termination-event.json
```

```json
{
  "eventId": "EMP-1023-2026-09-30",
  "receiptId": "RCP-5f95f8",
  "executed": 3,
  "needsReview": 0,
  "executionLog": [
    "Would notify the direct manager for EMP-1023-2026-09-30 by 2026-10-01 (termination.md)",
    "Would issue final paycheque for EMP-1023-2026-09-30 by 2026-10-07 (termination.md)",
    "Would send benefits continuation notice for EMP-1023-2026-09-30 by 2026-10-14 (termination.md)"
  ]
}
```

`201`, about 4.6 seconds. Offsets of 1, 7 and 14 days from 2026-09-30 — all three correct.

### An event no policy covers

A relocation request. Nothing in the corpus addresses relocation:

```json
{ "eventId": "EMP-4412-2026-12-01", "executed": 0, "executionLog": [] }
```

`201` with nothing to do. **This is a pass, not a failure.** A populated `actions` array here
would mean the model invented policy.

### A plan that doesn't survive checking

Take a valid plan and change one date — right clause, right offset, wrong arithmetic:

```json
{ "deadline": "2026-10-25", "deadlineRuleDays": 14, "effectiveDate": "2026-09-30" }
```

```json
{
  "valid": false,
  "errors": [
    "actions[0].deadline: 2026-10-25 does not equal effectiveDate 2026-09-30 + 14 days (expected 2026-10-14)"
  ]
}
```

`400`. The citation is genuine, the offset is genuine, the date is wrong — and it's caught
because the model had to report both halves of the calculation.

### Low confidence

```json
{
  "executed": 0,
  "needsReview": 1,
  "reviewQueue": [
    "Would notify the direct manager for EMP-55-2026-09-30 by 2026-10-01 (termination.md) [confidence 0.42 below 0.70]"
  ]
}
```

`201` — accepted, recorded, not executed.

### The full suite

```
$ ./scripts/test-e2e.sh

── Full pipeline — happy paths
  PASS  QC termination — 3 action(s) executed
  PASS  ON termination — 3 action(s) executed
  PASS  Medical leave request — 2 action(s) executed
  PASS  Benefits status change — 1 action(s) executed

── Full pipeline — adversarial
  PASS  Uncovered event (relocation) — no actions invented

── Deterministic layer in isolation (bypasses n8n)
  PASS  Correct clause, wrong date arithmetic — 400
  PASS  Hallucinated actionType — 400
  PASS  Missing sourceClause (uncited action) — 400
  PASS  Deadline before effectiveDate — 400

── Confidence routing
  PASS  confidence 0.42 queued for review, not executed

  13 passed, 0 failed
```

---

## 9. Things that went wrong

The failures were more instructive than the successes, and every one was quiet.

### The empty store returned success

After restarting the orchestrator, an event produced no response at all. The execution log said
**`success`**.

Retrieval had returned zero results — the vector store is in-process memory and the restart
wiped it. Zero results meant every downstream node was skipped, so nothing ever responded. No
error was raised because, structurally, nothing failed.

The fix is a guard that treats "no results" as a distinct condition:

```json
{ "error": "vector store is empty",
  "detail": "No policy chunks are indexed. The in-memory store does not survive a restart.
             Run: curl -X POST .../webhook/reindex-policies -d '{}'" }
```

`503`, naming the exact fix. **Generalisable lesson:** in a pipeline, an empty result set and a
failure often need the same treatment. Zero rows silently skipping the rest of the pipeline is a
very easy bug to ship.

### Activating is not publishing

The orchestrator has both an "activate" and a "publish" operation. Activate registers the
webhook in the *running process*; publish persists it. Everything worked until the first
restart, when the endpoint started returning `404`.

**Lesson:** test a restart before you believe anything is deployed. Behaviour that only exists in
a running process is invisible until the process stops.

### A documented restriction that wasn't the real one

File reads failed with `Access to the file is not allowed.` The node's own documentation said
the restriction was cloud-only — technically true, and irrelevant, because a *separate*
platform-wide default restricted file access to a specific directory.

**Lesson:** when the docs say the restriction doesn't apply and it demonstrably does, the
restriction you're reading about is not the one you've hit.

### Clearing the store, repeatedly

`clearStore` empties the store before inserting. It's read *inside* the per-batch insert loop,
not before it. Under the default batch size of 200, a corpus producing more than 200 chunks
would have each batch wipe the last — leaving only the final batch, silently. At 11 chunks this
never triggers, which is exactly what makes it dangerous: it would first appear when the corpus
grew.

### An error the citations caught

On the leave-request event, `flag_leave_request` cited Clause 3.1 (medical certificate, 2 days)
rather than Clause 2.1 (flag the request, 2 days). Both say 2 days, so the deadline is right —
the citation points one clause off.

This is worth dwelling on. The output was *correct*. The reasoning was *subtly wrong*. It was
visible only because every action has to carry its source. Without the citation requirement it
would have passed as a clean result forever.

That's the argument for citations in one example: they don't just support the answer, they
expose reasoning that happens to land on the right answer for the wrong reason.

---

## 10. What I'd do differently at scale

Honest limits of this build, and what changes if it were real:

| Now | At scale | Why |
|---|---|---|
| In-memory vector store | PGVector or Qdrant | Survives restarts; no re-indexing ritual |
| Re-index manually | Re-index on policy change | File watcher or CI hook on the policy repo |
| Top-3 retrieval | Tune per event type, add reranking | Would likely fix the mis-cited clause in §9 |
| Chunk by character count | Chunk on clause boundaries | Chunks would align with the citation unit |
| Fixed 0.7 confidence threshold | Per-action-type thresholds | Ending benefits deserves more caution than notifying a manager |
| In-memory receipts | Durable store | Compliance evidence has to outlive the process |
| Simulated execution | Real integrations, idempotency keys | Retries must not send two notices |

Two things I would keep exactly as they are: **the citation requirement** and **recomputing
every deadline**. They cost almost nothing and they are the only reason the failures in §9 were
findable.

---

## Summary

The pattern generalises beyond HR compliance to any domain where a model proposes actions with
real consequences:

1. **Write source documents the model can quote** — numbered, self-contained, with explicit
   numbers rather than vague language.
2. **Carry provenance through every stage** — the citation is only as good as the metadata
   behind it.
3. **Require the model to show its work** — report the inputs to a calculation, not just the
   result, so the result can be checked.
4. **Validate deterministically, separately, and testably** — in something you can exercise
   without the model in the loop.
5. **Make "I don't know" a first-class answer** — and test that it actually happens.
6. **Treat empty results as a distinct case** — not as a quiet no-op.

The AI does the part it's good at: reading prose and proposing structure. Code does the part it's
good at: arithmetic, enums, and refusing.
