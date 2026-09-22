# Benefits Eligibility Policy

**Document ID:** HR-POL-003
**Applies to:** All employees in Canadian operations
**Last reviewed:** 2026-01-28

## 1. Scope

This policy governs eligibility for group health, dental, and retirement benefits, and the
actions triggered by hire, status change, and qualifying life events. The effective date
referenced throughout this document is the date the eligibility change takes effect.

## 2. New hire enrolment

> **Clause 2.1** — Benefits enrolment must be opened for a newly eligible employee within 5 days
> of the eligibility effective date.

> **Clause 2.2** — An employee who does not complete enrolment within 31 days of the eligibility
> effective date is enrolled in default coverage at the single-participant tier.

Action: `open_benefits_enrollment`

## 3. Eligibility criteria

> **Clause 3.1** — Full-time employees working 30 or more hours per week are eligible for group
> health and dental coverage on their date of hire.

> **Clause 3.2** — Part-time employees working between 20 and 29 hours per week become eligible
> after 90 days of continuous service.

> **Clause 3.3** — Employees working fewer than 20 hours per week and contractors are not
> eligible for group coverage.

## 4. Status changes

> **Clause 4.1** — Where an employee's status changes between full-time and part-time, a
> benefits review must be scheduled within 15 days of the status change effective date to
> confirm continued eligibility and adjust premium deductions.

> **Clause 4.2** — A reduction in hours below 20 per week ends group coverage eligibility. The
> continuation notice requirements in HR-POL-001 Clause 4.1 apply to the resulting loss of
> coverage.

Action: `schedule_benefits_review`

## 5. Qualifying life events

> **Clause 5.1** — Marriage, birth or adoption of a child, divorce, or loss of spousal coverage
> are qualifying life events that permit a mid-year change to benefit elections.

> **Clause 5.2** — A qualifying life event opens a special enrolment window. Enrolment must be
> opened within 5 days of the event effective date, and the employee has 31 days from the event
> date to submit changes.

Action: `open_benefits_enrollment`

## 6. Retirement plan

> **Clause 6.1** — Employees become eligible for the group retirement plan after 12 months of
> continuous service.

> **Clause 6.2** — A benefits review must be scheduled within 15 days of the retirement plan
> eligibility date to complete contribution elections.

Action: `schedule_benefits_review`

## 7. Provincial variation

> **Clause 7.1** — In Quebec, employees must hold prescription drug coverage either through the
> group plan or through RAMQ. Employees declining group coverage must attest to RAMQ enrolment
> at the time of declination.
