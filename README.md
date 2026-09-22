# Policy-Grounded HR Compliance Agent

A RAG pipeline that grounds AI-generated HR compliance actions in source policy text, with a
deterministic Java validation layer separating AI proposal from execution.

> **Status:** work in progress. The Java validation layer is complete and verified; the n8n
> workflows are in build. See [Current state](#current-state).

---

## The idea

An LLM is good at reading policy prose and proposing what should happen. It is unreliable at
arithmetic, at staying inside an enum, and at admitting when it doesn't know.

So this system splits those responsibilities:

- **AI proposes.** n8n retrieves the relevant policy clauses; Claude drafts a structured action
  plan and must cite the clause behind every action.
- **Deterministic code disposes.** A Java service validates that plan against a JSON Schema,
  independently recomputes every deadline, and only then executes.

**The AI half cannot cause an incorrect action to execute.** The worst it can do is produce a
plan that gets rejected — a logged, visible outcome rather than a silent error.

### The check that matters

Claude must emit *both* the day offset it read from the policy (`deadlineRuleDays`) and the date
it computed (`deadline`). Java asserts they agree:

```
deadline == effectiveDate + deadlineRuleDays
```

This catches a realistic failure that a schema alone cannot: the model cites the correct clause,
extracts the correct number, and still gets the date wrong.

```
POST /api/action-plans
{ "effectiveDate": "2026-09-30",
  "actions": [{ "deadline": "2026-10-25", "deadlineRuleDays": 14, ... }] }

400 Bad Request
{ "valid": false, "errors": [
    "actions[0].deadline: 2026-10-25 does not equal effectiveDate 2026-09-30 + 14 days (expected 2026-10-14)"
]}
```

Requiring the model to show its work is what makes the error detectable.

---

## Architecture

```
┌─ n8n (Docker, :5678) ────────────────────────────────────────────┐
│                                                                  │
│  INDEXING (once)                                                 │
│    policies/*.md → chunk → Gemini embed → in-memory vector store │
│                                                                  │
│  RUNTIME (per event)                                             │
│    POST /hr-event → retrieve top-3 clauses                       │
│                  → Claude Sonnet 5 drafts a schema-bound plan    │
│                  → POST ─────────────────┐                       │
│                  ◄─ branch on status ◄───┼──┐                    │
└──────────────────────────────────────────┼──┼────────────────────┘
                   host.docker.internal    │  │ 201 / 400
┌─ Java Spring Boot 4.1 / Java 25 (:8080) ─▼──┴────────────────────┐
│    1. JSON Schema validation   (structure, enum, ranges)         │
│    2. Semantic validation      (deadline arithmetic, ordering)   │
│    3. Confidence routing       (≥0.7 execute, <0.7 needs review) │
│    4. Execute (simulated) + log + return receipt                 │
└──────────────────────────────────────────────────────────────────┘
```

| Component | Choice | Why |
|---|---|---|
| Orchestration & RAG | n8n 2.40 | Visual pipeline; the retrieval step is inspectable |
| Embeddings | Gemini `gemini-embedding-001` | Anthropic has no embeddings API; Gemini's free tier makes this $0 |
| Drafting LLM | Claude Sonnet 5 | Structured extraction from short retrieved chunks |
| Vector store | n8n in-memory | 3-document corpus; zero extra infrastructure |
| Validation | Spring Boot + networknt JSON Schema | Independently testable with no LLM in the loop |

Full rationale in [`docs/architecture.md`](docs/architecture.md).

---

## Validation behaviour

Every case below is verified:

| Input | Caught by | Result |
|---|---|---|
| Valid plan | — | 201 + receipt with execution log |
| Correct clause, **wrong date arithmetic** | Java semantic check | 400, expected vs. actual |
| Hallucinated `actionType` | JSON Schema enum | 400 naming the bad value |
| Missing `sourceClause` | JSON Schema | 400 — no citation, no action |
| `confidence: 0.42` | Confidence routing | 201, queued for review, **not executed** |
| Event no policy covers | Prompt instruction | `actions: []` — correct, not a failure |
| Malformed JSON | Parse guard | 400 |

Errors are reported as a list, not first-failure, so one round trip surfaces every problem.

---

## Running it

**Prerequisites:** Java 25, Docker. Maven is *not* required — the Maven wrapper ships with the
project.

```bash
# 1. Java validation service
cd java-service && ./mvnw spring-boot:run          # :8080

# 2. Mount policies into n8n (recreates the container; state is safe in the n8n_data volume)
./scripts/setup-n8n-volume.sh

# 3. In the n8n UI, create two credentials:
#      "Gemini - HR Agent"     (Google Gemini(PaLM) Api)
#      "Anthropic - HR Agent"  (Anthropic)

# 4. Import the workflows from n8n/, run the indexing workflow once, then:
curl -s -X POST http://localhost:5678/webhook/hr-event \
  -H 'Content-Type: application/json' \
  -d @sample-events/termination-event.json | jq
```

API keys live only inside n8n as credentials and are never stored in this repo.

---

## Repo layout

| Path | |
|---|---|
| `policies/` | Three HR policy documents with numbered, quotable deadline clauses |
| `java-service/` | Spring Boot validation + execution service |
| `n8n/` | Exported workflow JSON |
| `sample-events/` | Happy paths plus an event no policy covers |
| `docs/` | [architecture](docs/architecture.md) · [data flow](docs/data-flow.md) · [JSON contracts](docs/json-contracts.md) |
| `PROGRESS.md` | Build log, configuration registry, pinned node versions |

---

## Current state

| | |
|---|---|
| ✅ | Policy corpus, JSON contracts, architecture docs |
| ✅ | Policies mounted into the n8n container (read-only) |
| ✅ | **Java validation + execution service — complete and verified** |
| 🔜 | n8n indexing workflow |
| 🔜 | n8n runtime workflow |
| 🔜 | End-to-end and adversarial test scripts |

---

## Deliberate non-goals

Scoped as a demonstration of the proposal/execution boundary, not as production software:

- No authentication — both services are localhost-only
- No persistence — action plans live in memory
- Execution is simulated; `ActionExecutor` logs what it *would* do
- The in-memory vector store does not survive a container restart (re-run indexing)

None of these change the architecture.
