# Sample Events

Inputs for `POST http://localhost:5678/webhook/hr-event`. Fire them all with
`scripts/test-e2e.sh`, or individually:

```bash
curl -s -X POST http://localhost:5678/webhook/hr-event \
  -H 'Content-Type: application/json' \
  -d @sample-events/termination-event.json | jq
```

## Happy paths

| File | What it exercises | Expected |
|---|---|---|
| `termination-event.json` | QC termination. The province should pull Quebec's final-pay clause (3.2) rather than Ontario's (3.3). | 3–5 actions from `termination.md`, all 201 |
| `leave-request-event.json` | 45-day medical leave in ON. Duration exceeds the 15-day threshold in Clause 2.2 and the 10-day threshold in 4.1. | `flag_leave_request` + `schedule_return_to_work_check`; likely `schedule_benefits_review` (>90 days does not apply, so its absence is also correct) |
| `benefits-change-event.json` | Full-time to part-time at 24 h/week. Still eligible under Clause 3.2, so this is a review not a termination of coverage. | `schedule_benefits_review`, 15-day deadline |
| `termination-ontario-event.json` | Same event type as the first, different province. | Ontario's Clause 3.3 should be cited instead of 3.2 — run both and diff to show retrieval discriminating |

## Adversarial

| File | What it exercises | Expected |
|---|---|---|
| `uncovered-event.json` | A relocation request. **No policy covers this.** | `actions: []` and HTTP 201. Any populated `actions` array is a hallucination and a genuine failure. |

The tampered-deadline case is not a file — `scripts/test-e2e.sh` generates it by mutating a
valid plan and POSTing it straight to the Java service, bypassing n8n. That isolates the
deterministic layer and proves it rejects bad arithmetic that the LLM would have waved through.
