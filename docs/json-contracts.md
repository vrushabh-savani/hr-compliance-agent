# JSON Contracts

Three payloads cross a boundary in this system. Each is defined once here. The action-plan
contract in Section 3 is the important one — it is the agreement between the AI half and the
deterministic half, and it is enforced by a JSON Schema that both n8n and Java load.

---

## 1. HR event (client -> n8n webhook)

`POST http://localhost:5678/webhook/hr-event`

```json
{
  "eventType": "termination",
  "employeeId": "EMP-1023",
  "effectiveDate": "2026-09-30",
  "province": "QC",
  "metadata": {
    "reason": "voluntary",
    "department": "engineering"
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `eventType` | string | yes | `termination`, `leave_request`, `benefits_change` |
| `employeeId` | string | yes | Format `EMP-####` |
| `effectiveDate` | ISO date | yes | Anchor for every deadline computed downstream |
| `province` | string | yes | Two-letter code. Drives provincial clause selection. |
| `metadata` | object | no | Free-form. Fed into the retrieval query text. |

---

## 2. Retrieved context (n8n internal, retrieval -> Claude)

Not exposed over the network — this is what the vector store hands the prompt.

```json
{
  "event": { "...": "the HR event above" },
  "retrievedChunks": [
    { "source": "termination.md", "text": "Clause 4.1 — A written notice describing..." },
    { "source": "termination.md", "text": "Clause 5.1 — Benefits are end-dated 30 days..." }
  ]
}
```

`source` comes from the `sourceDocument` metadata attached at indexing time. Claude must cite it
verbatim — that citation is what makes the output auditable.

---

## 3. Action plan (Claude -> Java) — the contract that matters

`POST http://localhost:8080/api/action-plans`

```json
{
  "eventId": "EMP-1023-2026-09-30",
  "eventType": "termination",
  "effectiveDate": "2026-09-30",
  "actions": [
    {
      "actionType": "send_continuation_notice",
      "deadline": "2026-10-14",
      "deadlineRuleDays": 14,
      "sourceClause": "A written notice describing the employee's options for continuing health coverage must be sent within 14 days of the termination date.",
      "sourceDocument": "termination.md",
      "confidence": 0.92
    },
    {
      "actionType": "end_benefits",
      "deadline": "2026-10-30",
      "deadlineRuleDays": 30,
      "sourceClause": "Benefits are end-dated 30 days after the last day of employment.",
      "sourceDocument": "termination.md",
      "confidence": 0.88
    }
  ]
}
```

### Deviation from `project-brief.md` §3.3

The brief's contract has only `eventId` and `actions[]`, but states the rule *"`deadline` must be
on or after the event's `effectiveDate`."* That rule is unenforceable without `effectiveDate` in
the payload — the Java service would have to trust a date it never received.

**We add `effectiveDate` and `eventType` to the root.** This makes the service self-contained and
unlocks a materially stronger check than the brief proposed:

```
deadline == effectiveDate + deadlineRuleDays
```

An LLM can cite the correct clause, extract the correct offset, and still do the date arithmetic
wrong. That is exactly the failure class the deterministic layer exists to catch, and it is the
most convincing thing to demonstrate.

### Field rules (Java enforces all of these)

| Field | Rule | On violation |
|---|---|---|
| `eventId` | required, non-empty | 400 |
| `eventType` | required, non-empty | 400 |
| `effectiveDate` | required, ISO `YYYY-MM-DD` | 400 |
| `actions` | required array; **may be empty** | empty is valid — see below |
| `actionType` | must be one of the 9 known values | 400, unknown value named |
| `deadline` | ISO date, **on or after** `effectiveDate` | 400 |
| `deadlineRuleDays` | integer >= 0, and `effectiveDate + deadlineRuleDays == deadline` | 400, both dates reported |
| `sourceClause` | required, non-empty | 400 — no citation, no action |
| `sourceDocument` | required, must be a real policy filename | 400 |
| `confidence` | number in `[0, 1]` | 400 if absent or out of range |

**An empty `actions` array is a success, not a failure.** It is the correct response when
retrieval does not cover the situation. Returning nothing is the desired behaviour; inventing an
action is the failure mode.

**Confidence routing:** actions with `confidence >= 0.7` are executed. Actions below `0.7` are
valid but routed to a needs-review queue instead of executing. This is a runtime branch, not a
validation error.

### `actionType` enum

| Value | Source policy |
|---|---|
| `send_continuation_notice` | termination.md |
| `end_benefits` | termination.md |
| `issue_final_paycheck` | termination.md |
| `request_asset_return` | termination.md |
| `notify_manager` | termination.md |
| `flag_leave_request` | leave-policy.md |
| `schedule_return_to_work_check` | leave-policy.md |
| `open_benefits_enrollment` | benefits-eligibility.md |
| `schedule_benefits_review` | benefits-eligibility.md |

---

## 4. Receipt (Java -> n8n)

**201 Created** — plan accepted:

```json
{
  "eventId": "EMP-1023-2026-09-30",
  "receiptId": "RCP-7f3a1c",
  "receivedAt": "2026-09-22T16:04:11Z",
  "executed": 2,
  "needsReview": 0,
  "executionLog": [
    "Would send continuation notice to EMP-1023 by 2026-10-14 (termination.md)",
    "Would end benefits for EMP-1023 on 2026-10-30 (termination.md)"
  ]
}
```

**400 Bad Request** — plan rejected. All errors are reported at once, not just the first:

```json
{
  "eventId": "EMP-1023-2026-09-30",
  "valid": false,
  "errors": [
    "actions[0].actionType: 'send_cobra_notice' is not a recognised action type",
    "actions[1].deadline: 2026-10-25 does not equal effectiveDate 2026-09-30 + 30 days (expected 2026-10-30)",
    "actions[2].sourceClause: required but missing"
  ]
}
```

---

## Schema location

The JSON Schema lives at `java-service/src/main/resources/action-plan-schema.json` and is the
single source of truth. The n8n Structured Output Parser node is configured with the same schema
so Claude is constrained at generation time and validated again at execution time.

Keeping one schema in two places is a real risk. If you change it, change both — and the
adversarial tests in `scripts/test-e2e.sh` are what catch the drift.
