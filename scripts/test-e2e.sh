#!/usr/bin/env bash
#
# End-to-end test. Fires every sample event through the full pipeline, then runs two
# adversarial cases straight at the Java service to isolate the deterministic layer.
#
# Prerequisites: Java service on :8080, n8n on :5678, both workflows active.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JAVA_URL="http://localhost:8080/api/action-plans"
N8N_URL="http://localhost:5678"

pass=0
fail=0

ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
head2() { echo; echo "── $1"; }

# ---------------------------------------------------------------- preflight

head2 "Preflight"
curl -fsS -o /dev/null "$JAVA_URL" 2>/dev/null \
  && ok "Java service reachable" \
  || { bad "Java service not reachable — run: cd java-service && ./mvnw spring-boot:run"; exit 1; }

curl -fsS -o /dev/null "$N8N_URL/healthz" 2>/dev/null \
  && ok "n8n reachable" \
  || { bad "n8n not reachable"; exit 1; }

# The vector store is in-process memory and dies with the container, so always re-index.
head2 "Re-indexing policies"
if curl -fsS -m 180 -o /dev/null -X POST "$N8N_URL/webhook/reindex-policies" \
     -H 'Content-Type: application/json' -d '{}' 2>/dev/null; then
  ok "indexing workflow completed"
else
  bad "indexing failed — is 'HR Compliance — Indexing' active?"
  exit 1
fi

# ---------------------------------------------------- full pipeline (happy)

run_event() {
  local file="$1" expect_actions="$2" label="$3"
  local body executed
  body=$(curl -s -m 180 -X POST "$N8N_URL/webhook/hr-event" \
    -H 'Content-Type: application/json' -d @"$REPO_DIR/sample-events/$file" 2>/dev/null)

  executed=$(printf '%s' "$body" | node -e \
    "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const j=JSON.parse(s);console.log(j.executed??'ERR')}catch(e){console.log('ERR')}})")

  if [[ "$executed" == "ERR" ]]; then
    bad "$label — no valid receipt: $(printf '%s' "$body" | head -c 160)"
    return
  fi

  if [[ "$expect_actions" == "zero" ]]; then
    [[ "$executed" == "0" ]] && ok "$label — no actions invented" \
                             || bad "$label — expected 0 actions, got $executed"
  else
    [[ "$executed" -gt 0 ]] && ok "$label — $executed action(s) executed" \
                            || bad "$label — expected actions, got none"
  fi
}

head2 "Full pipeline — happy paths"
run_event termination-event.json         some "QC termination"
run_event termination-ontario-event.json some "ON termination"
run_event leave-request-event.json       some "Medical leave request"
run_event benefits-change-event.json     some "Benefits status change"

head2 "Full pipeline — adversarial"
# Nothing in the corpus covers relocation. An empty actions array is the correct answer;
# a populated one means the model invented policy.
run_event uncovered-event.json zero "Uncovered event (relocation)"

# ------------------------------------------- deterministic layer, in isolation

# These bypass n8n entirely. The point is to prove the Java layer rejects bad plans on its
# own — not to test whether Claude happens to produce them.
expect_400() {
  local label="$1" payload="$2"
  local out code errs
  out=$(curl -s -w '\n%{http_code}' -X POST "$JAVA_URL" -H 'Content-Type: application/json' -d "$payload")
  code=$(printf '%s' "$out" | tail -1)
  if [[ "$code" == "400" ]]; then
    errs=$(printf '%s' "$out" | sed '$d' | node -e \
      "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s).errors.join(' | '))}catch(e){console.log('')}})")
    ok "$label — 400"
    echo "        ${errs:0:150}"
  else
    bad "$label — expected 400, got $code"
  fi
}

head2 "Deterministic layer in isolation (bypasses n8n)"

expect_400 "Correct clause, wrong date arithmetic" '{
  "eventId":"TAMPER-1","eventType":"termination","effectiveDate":"2026-09-30",
  "actions":[{"actionType":"send_continuation_notice","deadline":"2026-10-25","deadlineRuleDays":14,
    "sourceClause":"A written notice describing the employee'"'"'s options for continuing health coverage must be sent within 14 days of the termination date.",
    "sourceDocument":"termination.md","confidence":0.92}]}'

expect_400 "Hallucinated actionType" '{
  "eventId":"TAMPER-2","eventType":"termination","effectiveDate":"2026-09-30",
  "actions":[{"actionType":"send_cobra_notice","deadline":"2026-10-14","deadlineRuleDays":14,
    "sourceClause":"A written notice describing the options for continuing health coverage.",
    "sourceDocument":"termination.md","confidence":0.9}]}'

expect_400 "Missing sourceClause (uncited action)" '{
  "eventId":"TAMPER-3","eventType":"termination","effectiveDate":"2026-09-30",
  "actions":[{"actionType":"end_benefits","deadline":"2026-10-30","deadlineRuleDays":30,
    "sourceDocument":"termination.md","confidence":0.88}]}'

expect_400 "Deadline before effectiveDate" '{
  "eventId":"TAMPER-4","eventType":"termination","effectiveDate":"2026-09-30",
  "actions":[{"actionType":"notify_manager","deadline":"2026-09-01","deadlineRuleDays":1,
    "sourceClause":"The direct manager must be notified within 1 day of the termination being recorded.",
    "sourceDocument":"termination.md","confidence":0.9}]}'

head2 "Confidence routing"
low=$(curl -s -X POST "$JAVA_URL" -H 'Content-Type: application/json' -d '{
  "eventId":"LOWCONF-1","eventType":"termination","effectiveDate":"2026-09-30",
  "actions":[{"actionType":"notify_manager","deadline":"2026-10-01","deadlineRuleDays":1,
    "sourceClause":"The direct manager must be notified within 1 day of the termination being recorded.",
    "sourceDocument":"termination.md","confidence":0.42}]}' \
  | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);console.log(j.executed+'/'+j.needsReview)})")
[[ "$low" == "0/1" ]] && ok "confidence 0.42 queued for review, not executed" \
                      || bad "expected 0 executed / 1 review, got $low"

# ---------------------------------------------------------------- summary

echo
echo "────────────────────────────────"
echo "  $pass passed, $fail failed"
echo "────────────────────────────────"
[[ "$fail" -eq 0 ]] || exit 1
