# JLProject — Permanent Instructions for Codex

## Mission and priorities

You are working on an internal web application that will process confidential business schedules. Prioritize **schedule correctness, access security, data integrity, and auditability** over implementation speed. Do not invent features or extend an approved phase without authorization.

## Language contract — mandatory

- **All prompts, project documentation, architecture notes, code comments, tests, technical summaries, and internal identifiers must be written in English.**
- **Every user-facing part of the application must be in Brazilian Portuguese (`pt-BR`)**: navigation, headings, field labels, buttons, statuses, validation messages, alerts, confirmation dialogs, tooltips, empty states, authentication, exports intended for end users, and accessibility labels.
- Use the `pt-BR` locale for date presentation (`DD/MM/YYYY`), while storing schedule dates as ISO civil dates (`YYYY-MM-DD`) and audit timestamps as UTC instants. Never depend on browser locale defaults for business data.
- Preserve Portuguese business terminology and literal Excel headers when they represent source data or required UI text (e.g., `Disciplina`, `Etapa`, `Atividade de Produto`, `Início`, `Fim`, `Predecessora`, `Meta`). These literals are not untranslated documentation.
- Read `docs/09-LOCALIZATION.md` before implementing any UI or export feature. Do not mix English and Portuguese on a user-visible screen.
- Respond to implementation requests and report changes **in English**, unless the human explicitly asks otherwise. The human may discuss requirements conversationally in Portuguese; that does not change the documentation/UI language contract.

## Sources of truth (priority order)

1. `docs/08-TESTS-AND-DECISIONS.md` — explicit product decisions and open questions.
2. `docs/01-PRD.md` — MVP scope and product semantics.
3. `docs/05-RESCHEDULING.md` — dependency and scheduling behavior.
4. `docs/02-DATA-MODEL.md`, `docs/03-EXCEL-IMPORT.md`, `docs/04-GANTT-UX.md` — detailed domain contracts.
5. `docs/06-ARCHITECTURE-AND-SECURITY.md`, `docs/07-DELIVERY-PLAN.md`, `docs/09-LOCALIZATION.md` — implementation and presentation constraints.

When documentation conflicts or a critical requirement is ambiguous, explain the issue and propose a choice **before implementing irreversible behavior**.

## Working approach

- Before each phase, provide the goal, files to be changed, risks, and acceptance criteria.
- Deliver small, reviewable changes with relevant tests. Do not implement the entire MVP in one pass.
- Prefer strict TypeScript, narrowly scoped modules, and deterministic pure functions for schedule calculations.
- Do not change, delete, overwrite, or recalculate imported dates without an explicit user-authorized operation.
- **Completely ignore the source spreadsheet's `Predecessora` column** during initial import. Do not infer dependencies from names, IDs, row order, dates, or proximity.
- Every post-import date change, including automatic propagation, requires an immutable audit event, a reason, and an operation identifier.
- Batch edits and revision publication must be transactional: all changes and audit events commit together, or none do.
- Goals (date targets) do not automatically shift with dependencies; surface conflicts instead.
- Validate dependency cycles, access permissions, stale version tokens, and calendar consistency before committing.
- Preserve existing dates of unaffected tasks; **never move successor tasks earlier automatically**.
- Do not confuse deliverable labels in task names (`EC R01`) with JLProject schedule revisions (`R01`).

## Security and privacy

- Never commit secrets, tokens, credentials, `.env`, `.dev.vars`, or actual confidential spreadsheets.
- Never expose `DATABASE_URL` or privileged database credentials in browser-side code.
- Authenticate and authorize every business-data API operation server-side; deny access by default.
- Authentication is not authorization: require an active workspace membership with the appropriate role.
- Validate inputs, constrain uploads, prevent CSRF where applicable, rate-limit authentication attempts, and use parameterized SQL.
- Prevent spreadsheet formula injection in untrusted exported text, including values with leading whitespace/control characters before `=`, `+`, `-`, or `@`.
- Do not log raw business spreadsheets, personal information, passwords, cookies, or connection strings.
- Do not deploy confidential production data until security, import transactions, restore procedures, and backup procedures have been tested.

## Required completion report for each phase

1. Concise list of changes and files.
2. Tests for normal behavior, boundaries, failures, and permissions as relevant.
3. `lint`, `typecheck`, `test`, and `build` results, or an explicit reason they could not run.
4. Updated affected docs and any newly approved decisions in `docs/08-TESTS-AND-DECISIONS.md`.
5. Remaining risks and a suggestion for the next *reviewable* step.

## Current authorization boundary

The first Codex interaction is a **Phase 0 planning request only**. Do not create or modify application code until the human approves that plan. Later phases require separate prompts and approvals. See `CODEX-PHASE-0-PROMPT.md`.
