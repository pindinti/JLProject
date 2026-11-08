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
| D019 | Phase 0B uses `@neondatabase/serverless` exclusively in the Worker and connects local development only to an isolated Neon `development` branch. Production, Managed Better Auth, business tables, and browser database access remain unchanged. | Approved |
| D020 | Phase 0C.1 uses Neon Managed Better Auth on the `development` branch for identity only. Public sign-up is disabled; email verification is required. The Worker validates provider JWTs and denies all workspace access until Phase 0C.2 supplies active membership. | Approved for Phase 0C.1 |
| D021 | Phase 0C.2A stores workspace memberships and roles in PostgreSQL on the isolated development branch. The Worker derives identity from a verified Neon JWT and checks active membership and role from the database on each protected request. First-admin bootstrap is an explicit manual development operation. | Approved for Phase 0C.2A |
| D022 | Phase 0C.2A.1 explicitly bootstrapped the first `JLProject` development workspace and one active administrator membership for a uniquely verified development test identity. The operation is manual and does not grant privileges by signup order or client claims. | Approved for Phase 0C.2A.1 |
| D023 | For the current internal MVP of approximately 2–3 users, the product owner accepts that a previously issued JWT may remain usable for up to its existing 15-minute maximum age after provider session revocation. Signature, issuer, audience, expiry, issued-at, and maximum-age checks remain mandatory; every protected business request also checks current active workspace membership and role. Revisit revocation before broader production deployment. This is an accepted residual risk, not immediate revocation. | Approved for Phase 0C.2C |
| D024 | Only active workspace administrators may list or change existing memberships. Membership changes are serialized per workspace in PostgreSQL and may never remove the final active administrator. Additional identity onboarding and membership creation are deferred pending a reviewed provider-supported flow. | Approved for Phase 0C.2C |
| D025 | Phase 1A uses workspace-scoped, stable product UUIDs. Product names are case-insensitively unique across active and archived products in a workspace. Archiving retains the row; edits and archive operations require a current version token. Product `code`, schedules, and hierarchy children are deferred. | Approved Phase 1A development migration |
| D026 | Phase 1B.1 stores configurable product disciplines, workspace-shared stage code/color definitions, per-discipline ordered stages, and stable ordered activities. Composite foreign keys enforce workspace/product ancestry. No list of discipline or stage types is hardcoded or seeded. | Approved for Phase 1B.1 development migration |
| D027 | Until the dedicated audited date-edit operation is implemented, Phase 1B.1 activity dates are set only on creation. API metadata updates reject planned-date fields, and a database trigger rejects subsequent date changes. Stage dates are derived and never stored. | Approved for Phase 1B.1 development migration |
| D028 | Phase 1B.2 exposes hierarchy metadata editing to active admin/editor members through the existing Worker API. A read-only stage-definition endpoint supports workspace code/color selection. Existing activity dates remain read-only; no migration or scheduling behavior is added. | Approved for Phase 1B.2 |
| D029 | Phase 1C.1 parses a bounded `.xlsx` workbook locally in the browser for preview only. It ignores predecessor, duration, and Gantt presentation columns, preserves source dates and labels, excludes `Meta` rows from operational activities, and flags uncertain official-target reconciliation. No import write path or database migration is introduced. | Approved for Phase 1C.1 |
| D030 | Phase 1C.2 reconciles source `Meta` rows with official targets by exact normalized name/date or an explicitly confirmed unique date-only candidate. An authorized Worker submits a bounded structured payload to one PostgreSQL import function, creating a new product and immutable R00 atomically; it never creates dependencies or overwrites a product. The development-only additive migration was applied after separate explicit approval. Real confidential workbook persistence requires separate explicit approval. | Approved for Phase 1C.2 |

## Pending security decision

| ID | Finding and required choice | Status |
|---|---|---|
| P001 | Before broader production deployment, select and verify a provider-supported immediate revocation mechanism or explicitly reassess the bounded JWT replay window. The current internal MVP accepts the 15-minute maximum-age limit under D023. | Deferred production review |

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

- [x] Worker tests using locally signed JWTs reject missing, malformed, expired, incorrectly signed, wrong-audience, unverified, and banned tokens without exposing token details.
- [x] Mocked authentication UI tests cover loading, failed credentials, session restoration, expired session, access pending, logout, recovery/reset, and verification form states.
- [x] Phase 0C.1 regression tests cover successful sign-in, application remount, asynchronous restoration, temporary restoration failure, logout followed by remount, and `iat` clock drift boundaries. Strict expiry and default workspace denial remain tested.
- [x] Real development-branch user test completed recovery email/password setup, sign-in, Worker JWT verification, and the access-pending response. A verified-email claim was accepted by the Worker. Email OTP delivery itself was not separately tested.
- [x] Real development-browser verification after the five-second `iat` skew fix: sign-in, pending access, reload persistence, tab reopen persistence, logout, and reload to login all passed. Mocked tests alone were not treated as proof of provider behavior.
- [x] Phase 0C.2A unit/API tests cover role permissions, inactive/missing memberships, cross-workspace and unknown resource IDs, client role spoofing, invalid/expired identity, and generic errors. A live unauthenticated membership request returned `401`; a signed-in development user saw `Acesso pendente` with no active membership. The development database has zero workspaces and zero memberships before manual bootstrap.
- [x] Phase 0C.2A.1 approved bootstrap committed one development workspace and one active admin membership. A read-only database join confirmed the intended verified identity; after reload, the signed-in application showed `Sessão autenticada`. The live membership endpoint returned `200` with `admin` for that workspace, `403` for another workspace ID, and `401` without credentials.
- [x] Phase 0C.2A.1 live browser reload preserved the authenticated view; logout followed by reload returned to login. Previously issued bearer-token revocation remains a separate unresolved gate.
- [x] The product owner accepted the bounded JWT revocation delay for the current small internal MVP; immediate revocation remains unimplemented and must be revisited before broader production deployment.
- [x] Phase 0C.2B investigation checked the managed instance's OpenAPI schema, actual JWT claim names, cookie-free `get-session`, the development auth session table schema, and the installed server toolkit. No safe JWT-to-session binding was found; revocation enforcement remains blocked and no authorization code was changed.
- [x] Controlled live replay reproduced the gap: protected membership endpoint `200` before logout, Neon SDK logout succeeded, and the same JWT still produced `200` immediately afterward. No token or cookie was logged or stored. This is a failed Phase 0C.2B acceptance result, not a passing revocation test.
- [x] Phase 0C.2C automated API and UI tests cover administrator listing, editor/viewer/inactive denial, cross-workspace denial, role/status changes, validation, last-admin conflicts, and generic failures. The additive function was verified on the JLProject development branch; read-only counts remained one workspace, one membership, and one active administrator. A signed-in development administrator saw the active admin in the local member list. No real membership mutation was performed.
- [x] Phase 1A: 56 automated tests pass, including product create/list/edit/archive, duplicate and stale-version handling, role checks, inactive membership, cross-workspace denial, invalid requests, and Portuguese loading/error states. The approved migration created an empty table on JLProject `development`. A signed-in administrator created one synthetic product, reloaded, and reopened its details; a read-only database check confirmed one active version-1 row with a creator identity. Mutation permissions for editor/viewer and archive remain automated-only, not live browser verified.
- [x] Phase 1B.1: the approved additive migration created four empty hierarchy tables and the date-protection trigger on JLProject `development`. A signed-in administrator created synthetic discipline/stage/activity rows through the Worker API, read the complete ordered hierarchy, confirmed empty and derived stage dates, received `409` for a stale edit, `400` for a date edit, and `403` for another workspace. A rollback-only database check passed stage aggregation, shared-code color conflict, and date-trigger assertions. Unauthenticated hierarchy access returned `401`; role and invalid-parent scenarios have automated coverage. No schedule editor UI was added.
- [x] Phase 1B.2 automated tests cover product-to-schedule navigation and reload, hierarchy display/collapse, empty groups, viewer restrictions, discipline/stage/activity creation and metadata editing, shared stage code/color selection, existing-date read-only behavior, client date validation and civil-date formatting, generic error/conflict states, and unauthorized API handling. The read-only catalog API test checks viewer access, cross-workspace denial, and disallowed writes. A signed-in development administrator also confirmed creation of a synthetic discipline, stage, and activity through the UI; after reload, the hierarchy and `DD/MM/YYYY` dates remained visible. This is user-reported browser verification, distinct from automated tests.
- [x] Phase 1C.1 synthetic parser and UI tests cover reference counts, preserved IDs/order/title text, excluded predecessors/formulas, 1900/1904 date boundaries, malformed headers, duplicate IDs, missing/invalid dates and ranges, distinct stage labels, ambiguous target matching, untrusted text, archive preflight, preview loading/error states, and absence of a persistence action. Real reference-workbook browser acceptance is tracked separately and is not implied by these tests.
- [x] A first real-workbook browser attempt exposed a file-picker focus regression: the global session refresh temporarily unmounted the Products view, losing the file input before its selection event. The import preview now has a stable route, and focus revalidation keeps the current view mounted while it checks the session. A regression test covers focus and route restoration. On repeat browser selection, the development administrator reported 46 source records, 41 operational activities, five unique targets, seven disciplines, zero dependencies, and a 21/10/2026–17/01/2028 source date span. No validation errors were reported. Three source `Meta` rows (15, 24, 50) have target-reconciliation warnings; these remain explicit review items, with no inferred mapping or persistence. No confidential row contents were added to project files.
- [x] Phase 1C.2: 106 automated tests pass, including target reconciliation, malformed/ambiguous submissions, protected import permissions, and frontend confirmation/error states. The additive migration was explicitly approved and applied only to JLProject `development`. A rollback-only synthetic database check passed counts, dates, provenance, idempotent replay, duplicate rejection, failure rollback, R00 immutability, and existing date-trigger behavior; all new tables remained empty after rollback. A live administrator sent concurrent identical synthetic imports through the local Worker (`201`/`200`), read seven disciplines, 21 stages, and 41 activities, and a read-only query confirmed one R00, five targets, 51 source references, and zero R00 dependencies. An unauthenticated import POST returned `401`. The actual confidential workbook was not persisted.
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
