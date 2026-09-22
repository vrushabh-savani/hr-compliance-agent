# Data Flow

Two flows: indexing runs once, runtime runs per event. Node names below match the n8n workflow
JSON exactly — if you rename a node in the UI, the `connections` object keys must change too.

---

## Flow 1 — Indexing

Run once after startup, and again after any policy edit or container restart.

```
Manual Trigger
      │ main
      ▼
Read Policy Files              n8n-nodes-base.readWriteFile
  ~/.n8n-files/policies/*.md   → one binary item per file
      │ main
      ▼
Extract From File              n8n-nodes-base.extractFromFile
  binary → text                → { data: "<markdown>" }
      │ main
      ▼
Prepare Documents              n8n-nodes-base.code
  derive docName from path     → { policyText, docName }
      │ main
      ▼
Simple Vector Store            vectorStoreInMemory  typeVersion 1.3
  mode: insert                 memoryKey: hr_policies
  clearStore: true             (wipes first, so re-runs are idempotent)
      ▲                    ▲
      │ ai_embedding       │ ai_document
      │                    │
Embeddings Gemini      Default Data Loader
gemini-embedding-001    jsonData: {{ $json.policyText }}
                        metadata.sourceDocument: {{ $json.docName }}
                             ▲
                             │ ai_textSplitter
                        Recursive Character Text Splitter
                        chunkSize 1000 / overlap 200
```

**Output:** roughly 15–25 chunks in the `hr_policies` store, each carrying a `sourceDocument`
metadata field.

**Why `clearStore: true`:** without it, re-running indexing appends a second copy of every
chunk, and retrieval starts returning duplicates that crowd out the top-k. With it, the workflow
is safely re-runnable.

**Why the Code node:** `ReadWriteFile` returns the full container path
(`/home/node/.n8n-files/policies/termination.md`), but the citation needs the bare filename (`termination.md`). The
Code node does that mapping and is the only place the two representations meet.

---

## Flow 2 — Runtime

```
Webhook  POST /hr-event                       typeVersion 2.1
  responseMode: responseNode
      │ main
      ▼
Simple Vector Store   mode: load              typeVersion 1.3
  memoryKey: hr_policies   topK: 3
  prompt: built from eventType + province + metadata
  includeDocumentMetadata: true
      ▲ ai_embedding
      │
Embeddings Gemini  (same model as indexing — non-negotiable)
      │
      │ main  → 3 chunks with text + sourceDocument
      ▼
Basic LLM Chain                                typeVersion 1.9
  hasOutputParser: true
  prompt: event + retrieved clauses + rules
      ▲                      ▲
      │ ai_languageModel     │ ai_outputParser
      │                      │
Anthropic Chat Model    Structured Output Parser
claude-sonnet-5         schema = action-plan-schema.json
      │
      │ main  → validated-shape action plan
      ▼
POST to Java Service                           typeVersion 4.5
  http://host.docker.internal:8080/api/action-plans
  neverError: true  ← must not throw on 400, we branch on it
      │ main
      ▼
IF  statusCode == 201                          typeVersion 2.3
      ├── true  ──► Respond Success   (receipt)
      └── false ──► Respond Rejected  (error list, HTTP 422)
```

### The embedding-model rule

The query in Flow 2 **must** use the same embedding model as Flow 1. Vectors from different
models are not comparable — retrieval will not error, it will just return nonsense ranked by a
meaningless distance. Both nodes use `gemini-embedding-001`.

### Why `neverError: true` on the HTTP node

A rejected plan is an expected outcome, not a workflow failure. Without this flag a 400 throws
and the webhook never responds, so the caller sees a timeout instead of the validation errors —
which are the most interesting output the system produces.

---

## Worked example

**Request**

```json
{
  "eventType": "termination",
  "employeeId": "EMP-1023",
  "effectiveDate": "2026-09-30",
  "province": "QC",
  "metadata": { "reason": "voluntary", "department": "engineering" }
}
```

**1. Retrieval query text**

```
termination voluntary engineering province QC — obligations, notices, deadlines
```

**2. Top-3 chunks** (all from `termination.md`): Clause 4.1 (continuation notice, 14 days),
Clause 5.1 (benefits end-date, 30 days), Clause 3.2 (Quebec final pay, 7 days).

The Quebec-specific clause surfaces because `province: "QC"` is in the query text — this is the
retrieval step visibly doing work rather than the model guessing from memory.

**3. Claude emits**

```json
{
  "eventId": "EMP-1023-2026-09-30",
  "eventType": "termination",
  "effectiveDate": "2026-09-30",
  "actions": [
    { "actionType": "send_continuation_notice", "deadline": "2026-10-14",
      "deadlineRuleDays": 14, "sourceDocument": "termination.md",
      "sourceClause": "A written notice describing the employee's options...",
      "confidence": 0.92 },
    { "actionType": "issue_final_paycheck", "deadline": "2026-10-07",
      "deadlineRuleDays": 7, "sourceDocument": "termination.md",
      "sourceClause": "In Quebec, all accrued and unused vacation pay must be included...",
      "confidence": 0.9 },
    { "actionType": "end_benefits", "deadline": "2026-10-30",
      "deadlineRuleDays": 30, "sourceDocument": "termination.md",
      "sourceClause": "Benefits are end-dated 30 days after the last day of employment.",
      "confidence": 0.88 }
  ]
}
```

**4. Java validates** — schema passes; then for each action
`2026-09-30 + 14 = 2026-10-14` ✓, `+ 7 = 2026-10-07` ✓, `+ 30 = 2026-10-30` ✓. All confidences
are above 0.7, so all three execute.

**5. Response — 201**

```json
{
  "eventId": "EMP-1023-2026-09-30",
  "receiptId": "RCP-7f3a1c",
  "executed": 3,
  "needsReview": 0,
  "executionLog": [
    "Would send benefits continuation notice for EMP-1023-2026-09-30 by 2026-10-14 (termination.md)",
    "Would issue final paycheque for EMP-1023-2026-09-30 by 2026-10-07 (termination.md)",
    "Would end benefits coverage for EMP-1023-2026-09-30 by 2026-10-30 (termination.md)"
  ],
  "reviewQueue": []
}
```

---

## Failure paths

These are the behaviours worth demonstrating — each one shows a layer doing its job.

| Scenario | Where it is caught | Result |
|---|---|---|
| Event no policy covers | Claude (prompt instruction) | `actions: []`, 201, nothing executed |
| Hallucinated `actionType` | Output parser, then Java enum check | 400 naming the bad value |
| Missing `sourceClause` | Java schema validation | 400 — no citation, no action |
| Correct clause, wrong date arithmetic | **Java semantic check** | 400 with expected vs. actual date |
| Deadline before `effectiveDate` | Java semantic check | 400 |
| Low-confidence action | Java confidence routing | 201, action queued for review not executed |
| Vector store empty after restart | Retrieval returns nothing | `actions: []` — re-run indexing |
| Java service down | HTTP node, `neverError` | IF false branch, 422 with the connection error |

The fourth row is the one to point at. Everything above it could be caught by a decent output
parser; recomputing the deadline needs an independent deterministic layer, which is the argument
the whole project is making.
