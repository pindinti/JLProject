# JLProject Schedule Printing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver read-only browser printing for individual and consolidated schedules, then add configurable print options incrementally.

**Architecture:** A dedicated print representation consumes existing schedule state and domain calculations, independent from interactive Gantt layout. Shared print document conventions and page partitioning support both views; native browser print handles physical output and PDF saving.

**Tech Stack:** Existing React, TypeScript, CSS, Vitest, and browser print APIs. No dependencies added.

**Spec:** `docs/14-SCHEDULE-PRINTING.md`

## Global Constraints

- Default paper is A3 landscape with 10 mm margins.
- User-facing content is Brazilian Portuguese; dates are `DD/MM/YYYY`.
- Printing is read-only and does not mutate schedules.
- Preserve custom colors, goals, milestones, and readable milestone names.
- Reuse the approved `public/brand/jlproject-logo.svg`.
- Native browser print preview and PDF saving are used; no custom engine or dependency.
- Do not merge into `main` or deploy to Production without explicit approval.

## Review focus

- Individual revision/scenario, hierarchy visibility, and explicit date bounds remain represented in output.
- Executive filters and expanded/collapsed rows match the current view.
- Horizontal and vertical pagination work together without clipping or omitting content.
- Rows are not split and parent headings are not orphaned, while whole branches are not forced together.
- Continuation pages retain document identification, hierarchy columns, timeline headers, footer, and page numbering.
- Print styles do not change persisted data or invoke mutation APIs.

---

## Phase 1: Default printable schedules

### Task 1: Shared print document and pagination

**Files:** Create focused print renderer/style and pagination modules under `src/`; add corresponding tests under existing test conventions; update `src/locales/pt-BR.ts`.

**Interfaces:**
- Pagination accepts ordered rows with hierarchy parent metadata and an inclusive civil-date interval; it returns page slices with row and date segments.
- Shared document accepts identification, issue date, page index/count, hierarchy headings, timeline ticks, and rendered row content.

- [x] Write focused failing tests for date segmentation, row capacity, combined horizontal/vertical page order, parent heading retention, and one-page boundaries.
- [x] Run the focused tests and verify they fail for the missing behavior.
- [x] Implement the smallest deterministic pagination helper and shared print document.
- [x] Add print CSS for A3 landscape, 10 mm margins, colors, footer, logo, repeated page identification/headers, and page numbering.
- [x] Run focused tests and typecheck.

### Task 2: Individual schedule printing

**Files:** `src/ScheduleWorkspace.tsx`, print renderer/style modules, `src/locales/pt-BR.ts`, focused component tests.

**Interfaces:** Consumes selected product schedule, visible rows, current scale date bounds, goals, current date, and configured row colors.

- [x] Add component coverage for print action, selected visible rows, and milestone names.
- [x] Render a print-only individual schedule with product identification, issue date, timeline bars, explicit dates, goals/milestones, and footer/page numbering.
- [x] Invoke `window.print()` from a Brazilian Portuguese print action; do not invoke schedule mutations.
- [x] Run component tests and typecheck.

### Task 3: Consolidated executive printing

**Files:** `src/ExecutiveGanttFull.tsx`, shared print renderer/style modules, `src/locales/pt-BR.ts`, focused component tests.

**Interfaces:** Consumes currently filtered products, visible rows from `visibleExecutiveFullRows`, current detail level/collapsed state, executive timeline dates, goals/milestones, and configured colors.

- [x] Add component coverage for collapsed output, print action, and visible milestone names.
- [x] Render a print-only executive schedule with current state, continuation headers, goals/milestones, and footer/page numbering.
- [x] Invoke native browser printing without schedule mutation calls.
- [x] Run component tests and typecheck.

### Task 4: Phase 1 verification

- [x] Add/complete automated coverage for schedules exceeding both page dimensions and verify date segments and source rows are covered, with parent headings repeated only for context.
- [x] Run lint, typecheck, full test suite, and build.
- [x] Obtain manual Chrome Save as PDF acceptance for individual v0.3 and the latest multi-product executive Products layout. Multi 05 Beach fits two A3 sheets; executive milestones stay inside their owning product plots. Retain the automated combined-pagination checks as separate evidence.
- [x] Record the user's manual acceptance and regression baselines in the specification, implementation notes and decision log.
- [x] Obtain an independent whole-branch review; fix Critical/Important findings and rerun relevant checks before Phase 2.

## Phase 2: Print configuration

Phase 2 is implemented and manually accepted functionally and visually in Chrome. The [detailed implementation plan](2026-11-24-print-configuration.md) records its authorized data boundary and the deferred backlog. The accepted Phase 1 PDFs remain visual regression baselines.

- [x] Add the configuration dialog for the living schedule, supported hierarchy detail, complete/visible/custom date ranges, automatic/width/single-page scaling, and readability warning.
- [x] Add optional goals/milestones and current-date indicator; use native browser print preview without a custom preview or PDF engine.
- [ ] **Deferred backlog:** Print actual formal revisions through an authorized immutable-snapshot reader; list only revisions that exist and preserve R00 immutability.
- [ ] **Deferred backlog:** Print dependency lines only when the selected representation has an authorized dependency graph available in frontend state.

## Orca work

The individual and executive renderers may be separate Orca tasks after shared conventions are established. Pagination verification is an integration task. Reuse the current Orca worktree; follow configured agent/model routing without manually assigning model settings or creating additional worktrees.
