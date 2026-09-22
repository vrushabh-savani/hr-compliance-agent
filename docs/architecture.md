# Architecture

## The idea

An LLM is good at reading policy prose and proposing what should happen. It is unreliable at
arithmetic, at staying inside an enum, and at admitting it does not know. So this system splits
those responsibilities down the middle:

- **n8n + Claude propose.** Retrieve the relevant policy text, draft a structured action plan,
  cite the clause behind every action.
- **Java disposes.** Validate the proposal against a hard schema, recompute every deadline, and
  refuse anything that does not hold up. Only then execute.

The interesting property is that **the AI half cannot cause an incorrect action to execute.**
The worst it can do is produce a plan that gets rejected, which is a logged, visible outcome
rather than a silent error. That boundary is the whole point of the project.

---

## Components

```
┌──────────────────────────────────────────────────────────────────────┐
│  n8n 2.40.5  (Docker, localhost:5678)                                │
│                                                                      │
│  Workflow 1: INDEXING (manual, run once)                             │
│    /policies/*.md ──► split ──► Gemini embed ──► in-memory store     │
│                                                                      │
│  Workflow 2: RUNTIME (webhook, per event)                            │
│    POST /hr-event ──► embed query ──► retrieve top-3                 │
│                  ──► Claude Sonnet 5 drafts plan (schema-constrained)│
│                  ──► HTTP POST ──────────────────┐                   │
│                  ◄── branch on status ◄──────────┼───┐               │
└──────────────────────────────────────────────────┼───┼───────────────┘
                        host.docker.internal:8080  │   │ 201 / 400
                                                   ▼   │
┌──────────────────────────────────────────────────────┴───────────────┐
│  Java Spring Boot 4.1.1 / Java 25  (host, localhost:8080)            │
│                                                                      │
│  POST /api/action-plans                                              │
│    1. JSON Schema validation   (structure, enum, ranges)             │
│    2. Semantic validation      (deadline arithmetic, date ordering)  │
│    3. Confidence routing       (>= 0.7 execute, < 0.7 needs review)  │
│    4. Execute (simulated) + log + persist in memory                  │
│                                                                      │
│  GET /api/action-plans  ──► everything recorded so far               │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Why each boundary exists

### Why a separate indexing workflow

Embedding the policy corpus is expensive relative to querying it and does not change per event.
Running it once and keeping the vectors resident means the runtime path is a single embedding
call plus a similarity search.

The cost of this split is a shared-state dependency between two workflows, which is where the
sharpest constraint in this project comes from — see *Vector store lifetime* below.

### Why the LLM output is schema-constrained twice

Claude is given the JSON Schema through n8n's Structured Output Parser, so generation is
constrained up front. Java then validates the same schema again on receipt.

This is not redundant. The parser constrains *shape*; it cannot check that
`2026-09-30 + 14 days` really is `2026-10-14`, that the cited clause exists, or that the
confidence is honest. Generation-time constraints reduce malformed output; receipt-time
validation is what makes the system trustworthy.

### Why Java rather than doing it in n8n

A Code node could do the same checks. Putting them in a separate service makes the boundary
explicit and independently testable: the validator can be exercised with curl, with no LLM, no
embeddings, and no n8n running. A reviewer can read `ActionPlanValidator` and see exactly what
the system will and will not permit — that is much harder to argue about when the rules live
inside a workflow node.

### Why the deadline is recomputed rather than trusted

`deadlineRuleDays` is the offset Claude extracted from the policy text; `deadline` is the date
it computed. Java asserts `effectiveDate + deadlineRuleDays == deadline`.

This catches a specific and realistic failure: the model cites the right clause, extracts the
right number, and still gets the date wrong. Requiring both the offset and the result makes that
error detectable, because the model has to show its work.

---

## Retrieval design

| Decision | Value | Reason |
|---|---|---|
| Chunk size | 1000 chars | Large enough to keep a numbered clause and its deadline together |
| Chunk overlap | 200 chars | Prevents a clause being split at its offset ("...within 14") |
| Top-k | 3 | Policies are short; more chunks mostly add distraction |
| Metadata | `sourceDocument` per chunk | Provides the citation Claude is required to emit |
| Embeddings | Gemini `gemini-embedding-001` | Free tier; Anthropic has no embeddings API |
| Store | Simple Vector Store (in-memory) | Per the brief; corpus is ~3 documents |

Chunking on clause boundaries is what makes the citation requirement workable. If a chunk ended
mid-clause, Claude would have to reconstruct the quote and `sourceClause` would stop being
verifiable against the source file.

---

## Vector store lifetime — the sharpest constraint

The Simple Vector Store is backed by `MemoryVectorStoreManager`, a **process-level singleton**
inside n8n. Two consequences:

1. **It survives between executions and between workflows — but only at `typeVersion >= 1.2`.**
   At `typeVersion <= 1.1` the memory key is namespaced `${workflowId}__${key}`, so the indexing
   workflow and the runtime workflow would each get their own empty store and retrieval would
   silently return nothing. **Both nodes are pinned to `typeVersion: 1.3`, and both use
   `memoryKey: "hr_policies"`.** This is the single easiest way to break the system.

2. **It does not survive a container restart.** After `docker restart n8n`, re-run the indexing
   workflow before anything else will work.

For production this would be PGVector or Qdrant. For a portfolio demo of the RAG pattern the
in-memory store is the right call — it keeps the dependency count at zero and the failure mode
is loud and easily explained.

---

## Security boundaries

- **API keys never enter the repo.** Gemini and Anthropic keys exist only as n8n credentials,
  referenced from workflow JSON by ID. The workflow files are safe to commit.
- **The n8n API key lives in `.env`**, which is gitignored. It is the one secret on disk.
- **Policies are mounted read-only** (`:ro`). n8n can index them; it cannot alter them.
- **The Java service is not exposed** beyond localhost and `host.docker.internal`.

---

## What this is not

Honest scoping, since a portfolio project invites the question:

- No authentication on either service — both are localhost-only.
- No persistence. Action plans live in an in-memory list and vanish on restart.
- Execution is simulated. `ActionExecutor` logs what it *would* do rather than sending mail or
  calling payroll.
- Single-tenant, no multi-org isolation.
- The vector store does not survive restarts, as above.

None of these are hard to add, and none of them change the architecture. The thing being
demonstrated is the proposal/execution boundary, and that is real.
