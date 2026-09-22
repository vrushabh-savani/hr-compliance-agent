# n8n Workflows

> `hr-compliance-indexing.json` is deployed and verified. The runtime workflow is not built yet.

Two workflows share one in-memory vector store.

| File | Trigger | Purpose |
|---|---|---|
| `hr-compliance-indexing.json` | Manual | Read `/home/node/.n8n-files/policies/*.md`, chunk, embed, insert |
| `hr-compliance-runtime.json` | Webhook `POST /hr-event` | Retrieve top-3, draft plan, validate via Java, respond |

## Importing

**UI:** Workflows → Import from File.

**API:**
```bash
set -a && . ../.env && set +a
curl -s -X POST http://localhost:5678/api/v1/workflows \
  -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' \
  -d @hr-compliance-indexing.json
```

The Public API is strict: `settings` is required, and `active` / `id` / `tags` are read-only on
POST — sending them returns a 400. Activate separately via
`POST /api/v1/workflows/{id}/activate`.

## Credentials

Referenced by ID; the workflow files contain no key material.

| Node | Credential type | Name |
|---|---|---|
| Embeddings Google Gemini | `googlePalmApi` | `Gemini - HR Agent` |
| Anthropic Chat Model | `anthropicApi` | `Anthropic - HR Agent` |

If you import into a different n8n instance, create credentials with these types and re-point
the nodes — the IDs in the JSON will not match.

## Publishing, not just activating

`POST /api/v1/workflows/{id}/activate` registers the webhook in the **running process only**.
After `docker restart n8n` the webhook returns 404. Use **publish**, which sets
`activeVersionId` and re-registers on boot:

```bash
curl -X POST http://localhost:5678/api/v1/workflows/{id}/publish -H "X-N8N-API-KEY: $N8N_API_KEY"
```

## Three things that will waste your time

**The vector store node must stay at `typeVersion` 1.3.** Below 1.2, n8n namespaces the memory
key per workflow (`${workflowId}__${key}`), so indexing and runtime get *separate* stores and
retrieval silently returns nothing — no error, just empty results. Both nodes use
`memoryKey: "hr_policies"`.

**Re-run indexing after any container restart.** The store is in-process memory and does not
survive `docker restart n8n`. The runtime workflow detects this and returns a 503 naming the
re-index command, rather than hanging — see below.

**An empty vector store used to fail silently.** Retrieval returning 0 items skips every
downstream node, so the webhook never responds and n8n still logs the execution as `success`.
The runtime workflow guards against it: `Retrieve Policy Clauses` sets `alwaysOutputData: true`,
`Assemble Prompt` flags `storeEmpty`, and the `Policies Indexed?` branch returns a 503. Keep
that branch if you edit the workflow.

Full node-by-node breakdown: [`../docs/data-flow.md`](../docs/data-flow.md).
