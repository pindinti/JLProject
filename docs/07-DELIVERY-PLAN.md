# 07 — Incremental Delivery Plan for Codex

**Operating rule:** deliver one verifiable phase at a time. Review acceptance criteria before starting the next phase. Make the app work locally before loading any real company data. Every user-facing UI element must be `pt-BR` from its first implementation.

## Phase 0 — Foundation and feasibility proof

**Goal:** establish a private repository and minimal React/TS/Vite + Cloudflare Workers setup, basic tests, documentation, local environment, server-only Neon connectivity proof, and an authentication-provider feasibility check without public access to company data.

**Deliverables:** minimal shell with a harmless placeholder protected-screen concept (not false production auth), non-sensitive API health endpoint, lint/test/typecheck/build scripts, `.gitignore`, `.env.example` with **no secrets**, and setup instructions.

**Acceptance:** the local build and tests work, no secret appears in git/frontend, the auth decision is recorded, and all visible UI copy uses `pt-BR`. **No Gantt implementation yet.**

## Phase 1 — Authentication, workspace and product CRUD

**Goal:** secure users/roles, workspace membership, minimal CRUD for products, disciplines, stages, activities, and targets; proper migrations and validation.

**Acceptance:** viewer cannot edit, editor cannot manage members, session without membership cannot read data, two accounts can work securely within one workspace, visible UI texts are Portuguese.

Phase 1B.1 implements the hierarchy schema and secure Worker API. Phase 1B.2 adds a compact schedule hierarchy editor using that API and a read-only stage-definition catalog endpoint. Activity dates remain immutable after creation until a dedicated audited operation is approved. Targets, importer, dependencies, revisions, and Gantt views remain later reviewable steps.
Phase 1C.1 adds client-only XLSX parsing, validation, and preview. It does not persist targets, activities, imports, or revisions. A later reviewable phase must design a transactional, authorized persistence endpoint and immutable original baseline before imported business data can be committed.
Phase 1C.2 supplies that reviewed structured write path, target reconciliation, and an additive initial R00 schema. It is limited to new-product imports and needs explicit approval before the development migration runs. Real confidential workbook persistence needs separate explicit approval. Gantt views, dependencies, scheduling, export, and later revisions remain separate phases.
Phase 1D.1/1D.1.1 deliver the detailed table/Gantt workspace and date navigation without changing schedule data. Phase 1D.2A implements the Phase 5 single-activity audited date-edit foundation in that contextual workspace. Its audit and limited Worker role migrations are installed in development; rollback-only synthetic database and user-assisted synthetic browser checks passed. Dependency propagation, later revisions, and portfolio scheduling remain separate reviewable steps.

## Phase 2 — Excel importer and baseline R00

**Goal:** `.xlsx` selection, mapping/preview, and import of activities and targets from Multi 05 Beach; immutable `R00`. **No dependencies created.**

**Acceptance:** 41 activities, five targets, seven disciplines, **zero dependencies**, exact source dates; no duplicate imports, full rollback on failure, useful validation report, no confidential payloads in logs.

## Phase 3 — Detailed Gantt

**Goal:** task/stage/discipline timeline, navigation, colors, dates, targets and filters.

**Acceptance:** overlaps remain visible; stage aggregations match child dates; Sunday target remains Sunday; imported source dates are unchanged.

Phase 3A.5a adds optional individual activity color overrides with stage-color inheritance and secure scoped persistence. Migrations `0023` and `0024` were applied once to JLProject Development after explicit approval. Rollback-only Worker checks passed for inheritance, override/reset, shared stage-color changes, optimistic version and workspace scopes, admin/editor cloning, independent R00 preservation, and narrow Worker grants. Recent-color history is reserved for Phase 3A.5b. Color metadata changes are not yet included in immutable product audit history; this known coverage gap must not be presented as audited behavior.

## Phase 4 — Consolidated portfolio Gantt

**Goal:** one logical product row with dynamic internal lanes for overlapping stages, color modes, and navigation to details.

**Acceptance:** each stage's full interval is visible at the correct time; lane packing never edits dates; product identity remains clear; goals only cross their associated product row.

## Phase 5 — Date edits and audit history

**Goal:** form-based editing with mandatory reason, append-only history, and optimistic concurrency.

**Acceptance:** missing reason fails server-side; history stores before/after, actor and time; without links, editing task A does not change task B; conflicting concurrent edits are rejected.

## Phase 6 — Dependencies and rescheduling engine

**Goal:** searchable predecessor selector, cross-discipline and stage/task links, FS first with advanced types after tests, impact preview and minimum-necessary forward moves.

**Acceptance:** no Excel dependency inference, multiple predecessors, cycles blocked, only required successors move, never automatic early moves, operation-grouped audit history, rollback on failure.

## Phase 7 — Scenarios, revisions, comparison

**Goal:** independent scenarios, immutable publication `R01+`, comparison of dates/targets/links, restore by publishing a new snapshot.

**Acceptance:** editing scenario leaves official revision untouched; R00 never mutates; restoring prior state creates a new revision and preserves all predecessors.

## Phase 8 — Export, hardening, production deployment

**Goal:** `.xlsx` export, E2E/security/performance coverage, independent backup/restore procedure, operational documentation, and Cloudflare deployment.

**Acceptance:** exported data matches selected revision, text is formula-safe, a backup has been restored in a separate environment, production authorization is verified, quota monitoring is documented.

## Per-phase Codex workflow

For each phase ask for:

1. A concise plan and exact files to change.
2. Implementation limited to the approved scope.
3. Relevant acceptance/security/locale tests.
4. `lint`, `typecheck`, `test`, `build` execution and results.
5. A short English summary of changed files, risks, and next review point.

**Do not implement the whole MVP in one prompt.** `CODEX-PHASE-0-PROMPT.md` asks for Phase 0 planning only.
