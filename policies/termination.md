# Termination Policy

**Document ID:** HR-POL-001
**Applies to:** All employees in Canadian operations
**Last reviewed:** 2026-01-15

## 1. Scope

This policy governs the employer's obligations when an employment relationship ends, whether
voluntarily (resignation, retirement) or involuntarily (dismissal, layoff, end of contract). The
effective date referenced throughout this document is the employee's last day of employment.

## 2. Manager notification

When a termination is recorded, the employee's direct manager must be notified so that access
revocation and workload reassignment can begin.

> **Clause 2.1** — The direct manager must be notified within 1 day of the termination being
> recorded.

Action: `notify_manager`

## 3. Final pay

> **Clause 3.1** — The final paycheque, including all outstanding regular wages, must be issued
> within 7 days of the last day of employment.

> **Clause 3.2** — In Quebec, all accrued and unused vacation pay must be included in the final
> paycheque and paid within 7 days of the last day of employment. No separate vacation payout
> cycle applies.

> **Clause 3.3** — In Ontario, outstanding wages including accrued vacation pay must be paid by
> the later of 7 days after employment ends or the employee's next regular pay date.

Action: `issue_final_paycheck`

## 4. Benefits continuation

> **Clause 4.1** — A written notice describing the employee's options for continuing health
> coverage must be sent within 14 days of the termination date.

> **Clause 4.2** — The continuation notice must state the cost of continued coverage, the
> election deadline, and the date coverage would otherwise lapse.

Action: `send_continuation_notice`

## 5. Benefits termination

> **Clause 5.1** — Benefits are end-dated 30 days after the last day of employment. Coverage
> remains active during this 30-day runout period.

> **Clause 5.2** — Where an employee elects continuation coverage under Clause 4.1, the
> end-dating in Clause 5.1 is suspended and coverage transfers to the continuation plan.

Action: `end_benefits`

## 6. Company assets

> **Clause 6.1** — A written request for the return of all company assets, including laptops,
> access cards, mobile devices, and corporate credit cards, must be issued within 3 days of the
> last day of employment.

> **Clause 6.2** — Assets not returned within 30 days of the request may be treated as a
> recoverable debt, subject to applicable provincial wage-deduction rules.

Action: `request_asset_return`

## 7. Voluntary vs. involuntary

The deadlines in Sections 2 through 6 apply identically to voluntary and involuntary
terminations. The reason for termination does not extend or shorten any statutory deadline.

## 8. Record retention

Termination records, including all notices sent under this policy, must be retained for a
minimum of 7 years. Retention is handled by the records system and requires no per-event action.
