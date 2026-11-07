# 08 — Acceptance Test Matrix, Decisions and Open Questions

**Specification version:** 0.2 — November 6, 2026.

## Product decisions approved in conversation

| ID | Decision | Status |
|---|---|---|
| D001 | JLProject is a web-based, multi-user application for confidential business schedule data. | Approved |
| D002 | Hierarchy is Product → Discipline → Stage → Activity; stage sets vary by discipline. | Approved |
| D003 | Detailed product Gantt displays disciplines, stages, tasks and overlaps. | Approved |
| D004 | Consolidated portfolio Gantt shows **all** discipline/stage bars, including overlaps, within one logical row per product. | Approved |
| D005 | Consistent colors by stage or discipline; user can switch coloring. | Approved |
| D006 | Unlimited user-configurable named target dates shown as vertical markers. | Approved |
| D007 | Import/export Excel; existing schedules are the starting point. | Approved |
| D008 | **Completely ignore legacy predecessor values at import**; use activity/structure/date data and goals instead. | Approved |
| D009 | Every date modification requires a note; rejection is only a reason, not a workflow/status. | Approved |
| D010 | Users create dependencies via an intuitive, searchable task/stage selector inspired by MS Project. | Approved |
| D011 | Dependencies can link tasks or stages across disciplines of the **same product**; multiple predecessors allowed. | Approved |
| D012 | Reschedule affected successors automatically with minimal necessary shifts, preserving other dates. | Approved |
| D013 | Immutable revisions and independent scenarios allow simulation and restoration without losing the baseline/history. | Approved |
| D014 | Build incrementally in VS Code with Codex; plan/document before implementation. | Approved |
| D015 | **All prompts, technical documentation and engineering communication are in English.** | Approved |
| D016 | **All user-facing application copy is Brazilian Portuguese (`pt-BR`).** | Approved |
| D017 | Each Codex prompt supplied in this chat must include a recommended model and reasoning-effort level chosen for efficiency. | Approved |
| D018 | Phase 0A uses React, strict TypeScript, Vite, Cloudflare Workers Static Assets, the official Cloudflare Vite plugin, Vitest, and ESLint. Neon connectivity remains deferred to Phase 0B. | Approved |

## Proposed technical assumptions, not yet verified by the business user

| ID | Assumption | Validation |
|---|---|---|
| H001 | Cloudflare Workers Static Assets + API, Neon PostgreSQL, React/TS/Vite. | Phase 0 provider/quotas PoC. |
| H002 | Managed Neon Auth / Better Auth is a suitable provider. | Verify login/invite/recovery/session/workspace access. |
| H003 | Default calendar Monday–Friday, with no custom holidays. | Confirm on real date change examples. |
| H004 | FS/TI is default; SS/II, FF/TT, SF/IT are advanced options. | Representative scheduling tests. |
| H005 | Never pull successors earlier automatically after an earlier predecessor finish. | Confirm operational preference. |
| H006 | Targets belong to products; in portfolio Gantt, lines stay within each product row. | UX review. |
| H007 | Only administrators publish revisions; editors can create scenarios. | Confirm team workflow. |
| H008 | Stage/discipline colors come from editable catalogs. | Test contrast and company conventions. |
| H009 | Moving a stage preserves relative child offsets; editing its end requires selecting terminal child task. | Prototype with actual user. |
| H010 | MVP XLSX is structured data, not a pixel-perfect reproduction. | Confirm export expectations. |
| H011 | Initial audit timestamp display timezone is `America/Sao_Paulo`. | Confirm with company users. |

Assumptions are not irrevocable decisions. Flag significant security, calendar, data-integrity or usability choices before implementation.

## Minimum acceptance test matrix

### Import

- [ ] Multi 05 Beach has 46 source records; import yields 41 operational activities and five business targets, without duplication.
- [ ] All original E/F dates survive unchanged; no imported dependencies; immutable original R00.
- [ ] Seven disciplines and eight source stage labels can be filtered; overall span is October 21, 2026–January 17, 2028.
- [ ] `Resumo Gantt` formulas do not determine imported dates.
- [ ] `R00` inside a task name does not create a schedule revision.
- [ ] Reimport, empty workbook, invalid dates, missing required fields, and mid-transaction errors produce proper reports and zero partial writes.
- [ ] Weekend targets remain on their exact dates, including Sunday.
- [ ] Import preview and validation errors are `pt-BR`, while internal code/test identifiers stay English.

### UI and localization

- [ ] Detailed Gantt shows all tasks inside their discipline/stage and correctly handles overlap.
- [ ] Portfolio Gantt uses one logical product row with as many internal visual lanes as necessary.
- [ ] Selecting color-by-stage assigns the same stage color to `EC` across disciplines.
- [ ] Target lines are positioned at their exact dates and are scoped to the correct product in portfolio view.
- [ ] Clicking a portfolio bar navigates to the correct detailed stage.
- [ ] Menus, buttons, dialogs, validation, login, tooltips, chart legends, accessibility labels, and empty/error states display Brazilian Portuguese.
- [ ] Calendar dates display as `DD/MM/YYYY`; stored schedule dates do not shift due to timezone conversions.
- [ ] User-entered and imported source descriptions retain their original content and accent characters.

### Date edits and dependency engine

- [ ] Missing date-change reason is rejected by the server.
- [ ] Date changes produce append-only before/after audit events with actor, instant and operation identifier.
- [ ] Editing an unlinked activity never changes another activity.
- [ ] FS chain A→B→C shifts only needed successors while independent D keeps its dates.
- [ ] A successor with sufficient existing slack remains unchanged.
- [ ] Multiple predecessors enforce the most restrictive valid bound; cycles are prohibited.
- [ ] Cross-discipline and group stage/task links respect stage aggregation and grouping semantics.
- [ ] Canceling a preview saves nothing; a failed commit never leaves unaudited date changes.
- [ ] Targets remain fixed and target breaches produce warnings.
- [ ] No automatic earlier move happens when a predecessor moves earlier.

### Revisions

- [ ] A scenario modifies its own dates without changing the baseline or current published revision.
- [ ] Publication creates a new immutable revision; R00 remains unchanged.
- [ ] Comparison detects date changes, created/deleted links, and target changes.
- [ ] Restoring an older revision creates a **new** revision and keeps intermediate history.

### Security and safety

- [ ] Unauthenticated clients cannot read or change business data via API.
- [ ] Authenticated users without active membership cannot read the workspace.
- [ ] Viewer cannot edit; editor cannot grant self admin privileges.
- [ ] Object IDs from another workspace/product cannot expose data (IDOR checks).
- [ ] Secrets are limited to the Worker environment; none appear in frontend JS, git, or logs.
- [ ] Malicious/invalid XLSX uploads are safely rejected; exported untrusted text cannot execute spreadsheet formulas.
- [ ] Optimistic concurrency prevents silent lost updates.
- [ ] Production backup has been restored successfully in a separate environment before go-live.

## Open questions to review with the business user (do not block Phase 0)

1. Business days versus calendar days; national/state/local holidays for dependency calculations.
2. Whether only admins can publish official revisions or delegated editors may do so.
3. How to handle one-day markers and activities scheduled on weekends.
4. Exact distinction between a company target (`Meta`) and an operational marker (`Marco`) in each Gantt.
5. Whether tasks can be explicitly locked against automatic movement, and how conflicts should be handled.
6. Expected simultaneous users/products/activities for performance sizing.
7. Whether the consolidated Gantt needs optional task-level display in addition to all stage bars.
8. Exact exported workbook columns and whether external stakeholders need a particular template.

## Documentation change policy

When a business decision is agreed: add/update a `D...` entry and revise relevant requirements/tests. When a technical decision is approved: record its context, alternatives, decision, and tradeoffs before implementation. Keep examples and source-data acceptance counts consistent across documents.
