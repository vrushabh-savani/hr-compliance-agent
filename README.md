# Policy-Grounded HR Compliance Agent

**A RAG pipeline that grounds AI-generated compliance actions in source policy text, with a
deterministic Java validation layer separating AI proposal from execution.**

`Java 25` · `Spring Boot 4.1` · `n8n` · `Claude Sonnet 5` · `Gemini embeddings` · `JSON Schema` · `Docker`

---

## The problem

An HR event happens — a termination, a leave request, a status change. Policy says certain
things must happen by certain dates. Miss one and it's a compliance problem.

Asking an LLM *"here's the event and the policy, what do we do?"* works until it doesn't, and the
failures are quiet: invented obligations, correct rule with wrong arithmetic, answers from
training data instead of your actual policy, and no audit trail. Every one produces output that
**looks** correct.

## The approach

Split the system in half:

- **AI proposes.** Retrieval pulls the relevant policy clauses; Claude drafts a structured plan
  and must cite the clause behind every action.
- **Deterministic code disposes.** A Java service validates against a hard schema, independently
  recomputes every date, and only then executes.

**The AI half cannot cause an incorrect action to execute.** The worst it can do is produce a
plan that gets rejected — logged and visible, not silent.

---

## Two design decisions carry the weight

### 1. The model must show its work

Claude emits **both** the day offset it read from the policy (`deadlineRuleDays`) **and** the
date it computed (`deadline`). Those are cross-checkable:

```
deadline == effectiveDate + deadlineRuleDays
```

A model returning only `deadline` gives you nothing to verify against. Requiring both turns an
opaque answer into a checkable claim:

```jsonc
// POST /api/action-plans  — right clause, right offset, wrong date
{ "effectiveDate": "2026-09-30",
  "actions": [{ "deadline": "2026-10-25", "deadlineRuleDays": 14, ... }] }

// 400 Bad Request
{ "valid": false, "errors": [
    "actions[0].deadline: 2026-10-25 does not equal effectiveDate 2026-09-30 + 14 days (expected 2026-10-14)"
]}
```

### 2. Every action must cite a verbatim clause

Not a summary — the actual policy text, plus the filename it came from. No citation, no action.

This caught a real error during development: on a leave request the model produced the *correct
deadline* while citing the *adjacent clause*. The answer was right; the reasoning was subtly
wrong. Without mandatory citations it would have passed as clean output forever.

---

## Architecture

```
┌─ n8n (Docker, :5678) ────────────────────────────────────────────┐
│                                                                  │
│  INDEXING  (run once, and after any policy edit)                 │
│    policies/*.md → chunk 1000/200 → Gemini embed → vector store  │
│                                                                  │
│  RUNTIME  (per event)                                            │
│    POST /hr-event → retrieve top-3 clauses                       │
│                   → Claude Sonnet 5 drafts a schema-bound plan   │
│                   → POST ────────────────┐                       │
│                   ◄─ branch on status ◄──┼──┐                    │
└───────────────────────────────────────────┼──┼───────────────────┘
                   host.docker.internal     │  │ 201 / 400
┌─ Java Spring Boot 4.1 / Java 25 (:8080) ──▼──┴───────────────────┐
│    1. JSON Schema validation   (structure, enum, ranges)         │
│    2. Semantic validation      (deadline arithmetic, ordering)   │
│    3. Confidence routing       (≥0.7 execute, <0.7 needs review) │
│    4. Execute + log + return receipt                             │
└──────────────────────────────────────────────────────────────────┘
```

| Component | Choice | Why |
|---|---|---|
| Orchestration & RAG | n8n 2.40 | The retrieval step stays inspectable |
| Embeddings | Gemini `gemini-embedding-001` | Anthropic has no embeddings API; free tier makes this $0 |
| Drafting LLM | Claude Sonnet 5 | Structured extraction from short retrieved chunks |
| Vector store | n8n in-memory | 3-document corpus; zero extra infrastructure |
| Validation | Spring Boot + networknt JSON Schema | Testable with `curl` alone — no LLM in the loop |

The same JSON Schema constrains the model at generation time *and* validates on receipt. That
isn't redundant: a schema constrains **shape**, and cannot check that `2026-09-30 + 14 days` is
really `2026-10-14`.

---

## Results

`./scripts/test-e2e.sh` — **13/13 passing**. End to end in ~4.6s per event.

| Case | Caught by | Result |
|---|---|---|
| Valid plan | — | `201` + receipt with execution log |
| **Correct clause, wrong date arithmetic** | Java semantic check | `400`, expected vs. actual |
| Hallucinated `actionType` | JSON Schema enum | `400` naming the bad value |
| Missing `sourceClause` | JSON Schema | `400` — no citation, no action |
| Deadline before `effectiveDate` | Java semantic check | `400` |
| `confidence: 0.42` | Confidence routing | `201`, queued for review, **not executed** |
| Event no policy covers | Prompt instruction | `actions: []` — correct, not a failure |
| Empty vector store | Pipeline guard | `503` naming the fix, rather than hanging |

Errors return as a list, not first-failure, so one round trip surfaces every problem.

### Retrieval is doing real work

Two identical termination events differing only in `province` cite **different clauses** from
the same document:

| `province` | Clause cited for `issue_final_paycheck` |
|---|---|
| `QC` | *"In Quebec, all accrued and unused vacation pay must be included in the final paycheque and paid within 7 days…"* |
| `ON` | *"In Ontario, outstanding wages including accrued vacation pay must be paid by the later of 7 days after employment ends…"* |

The province is part of the embedded query, so the correct provincial clause is **retrieved**
rather than recalled from training data. This is the test worth building for any RAG system:
find two inputs that *should* retrieve differently, and prove they do.

---

## Quick start

**Prerequisites:** Java 25 and Docker. Maven is *not* required — the wrapper ships with the
project.

```bash
# 1. Validation service
cd java-service && ./mvnw spring-boot:run            # :8080

# 2. Mount the policy corpus into n8n
#    (recreates the container; state is safe in the n8n_data named volume)
./scripts/setup-n8n-volume.sh

# 3. In the n8n UI at localhost:5678, create two credentials:
#      "Gemini - HR Agent"     → Google Gemini(PaLM) Api
#      "Anthropic - HR Agent"  → Anthropic

# 4. Import both workflows from n8n/ and PUBLISH them.
#    Activating alone does not survive a restart — see n8n/README.md.

# 5. Index the policies, then run everything
curl -X POST http://localhost:5678/webhook/reindex-policies -d '{}'
./scripts/test-e2e.sh
```

Send a single event:

```bash
curl -s -X POST http://localhost:5678/webhook/hr-event \
  -H 'Content-Type: application/json' \
  -d @sample-events/termination-event.json | jq
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

> **The vector store is in-process memory** and does not survive an n8n restart. Re-index with
> the command in step 5. Forget, and the pipeline returns a `503` naming the fix rather than
> failing quietly.

API keys live only inside n8n as credentials and never touch this repo.

---

## Repo layout

| Path | |
|---|---|
| `policies/` | Three HR policy documents with numbered, quotable deadline clauses |
| `java-service/` | Spring Boot validation + execution service |
| `n8n/` | Workflow JSON for indexing and runtime |
| `sample-events/` | Four happy paths plus an event no policy covers |
| `scripts/` | Container setup and the end-to-end suite |
| `docs/` | See below |

**Documentation**

- **[Walkthrough](docs/walkthrough.md)** — how it's built and why, with real output and the four
  silent failures hit along the way. Start here.
- [Architecture](docs/architecture.md) — components, boundaries, why the Java layer exists
- [Data flow](docs/data-flow.md) — node-by-node, both workflows, every failure path
- [JSON contracts](docs/json-contracts.md) — the three payloads and every field rule

---

## Scope

Built to demonstrate the proposal/execution boundary, not as production software:

- No authentication — both services are localhost-only
- No persistence — action plans live in memory
- Execution is simulated; `ActionExecutor` logs what it *would* do
- The vector store does not survive a restart

None of these change the architecture. What would change at scale — PGVector instead of
in-memory, clause-boundary chunking, per-action-type confidence thresholds, idempotency keys on
real integrations — is covered at the end of the [walkthrough](docs/walkthrough.md).

Two things would stay exactly as they are: **the citation requirement** and **recomputing every
deadline**. They cost almost nothing, and they are the only reason the subtle failures were
findable at all.
