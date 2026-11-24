# Schedule Printing Phase 2 Implementation Plan

**Status:** Implemented; all supported print configuration features passed manual functional and visual acceptance in Chrome on 2026-11-24. Formal revision and dependency printing are deferred backlog items. The approved Phase 1 individual v0.3 and executive Products PDFs remain visual regression baselines.

> **For agentic workers:** Use superpowers:executing-plans for native execution and one independent whole-branch review. Use the established Orca worktree and automatic agent/model routing. The user approved implementation with the narrower read boundary below.

**Goal:** Let users configure individual and executive prints through one compact dialog while preserving the approved defaults and native browser output.

**Architecture:** Keep draft dialog options separate from the live schedule and produce a print-only input at confirmation. Reuse the existing row builders, fixed A3 layout, offscreen measurement and native print handoff. Use only schedule versions and dependency data already available in authorized frontend state.

**Tech stack:** TypeScript, React, native Chrome printing, Vitest, and the existing Worker/PostgreSQL read path.

**Spec:** [Schedule printing specification](../../14-SCHEDULE-PRINTING.md#phase-2-approved-scope)

## Approved constraints and execution decisions

**Approved execution ruling:** The approval forbids new endpoints, migrations and authorization changes. This supersedes the proposed snapshot reads in Task 1. Inspection confirmed that import and clone responses expose revision metadata only, no authorized frontend state exposes a saved snapshot, and the existing live dependency reader is unregistered. Show the living schedule and disabled, explained revision and dependency choices. Keep the original read and graph steps below as deferred scope, not work to execute in this phase. The user approved 7 pt as a warning threshold rather than a restriction.

**Deferred backlog:** Formal revision printing may list only revisions that actually exist and must read immutable snapshots through a separately approved authorized path. Dependency printing may be enabled only for schedule representations whose graph is available through authorized frontend state. Neither feature may be implemented by reconstructing historical data or weakening authorization.

- No new dependencies, schema changes, writes to database records, or permission changes. Keep A3 landscape with 10 mm margins and all user-facing copy in Brazilian Portuguese.
- The current individual screen supplies only the living schedule. Show the available version and explain the absence of an authorized saved-version read. Keep stored baselines immutable and avoid assumptions about future revision names.
- The live graph is intentionally inaccessible to the Worker, and the executive projection has no graph. Existing frontend state does not expose the graph or saved snapshots. Disable dependency lines and give a localized explanation.
- In a limited date range, retain selected hierarchy rows and their original displayed start/end dates. Clip bars, one-sided markers and dependency geometry to the selected civil window. Keep goals and milestones outside that window off the dated plot and print their names and actual dates once as clearly labeled out-of-range details for the owning product, following the existing overflow convention. The current-date marker appears only if enabled and in range.
- The approved warning threshold is an effective **7 pt** for essential printed text. Also warn when a fit-width interval can no longer retain monthly labels at the target size, even if the font stays 8 pt. Let the user proceed or change the options. Keep approved typography in the default mode.

## Review focus

- Import and clone identifiers cannot substitute for readable historical snapshots. Verify there are no new readers or fabricated version choices.
- Cancel or Escape before confirmation must leave the screen and native print unchanged. Task 2 covers cancellation.
- A visible date range with a partially visible day and frozen executive column must use the same inclusive civil dates on the paper. Task 2 covers geometry.
- A long single-sheet document must include dense legends and milestones through scaling and warn before native print. Task 3 covers measurement and confirmation.
- Hiding milestones must not create a later blank sheet selected solely by a hidden milestone. Task 3 covers interval selection.

## 1. Saved version read proposal (deferred)

**Files:** `worker/schedule-api.ts`, `worker/schedule-repository.ts`, a focused snapshot adapter in `domain/print-revision.ts`, Worker route/repository and snapshot adapter tests. Reuse the existing protected router and product-existence checks.

- [ ] When an authorized reader exists, test an actual saved baseline, no baseline, cross-product access, missing membership, viewer and archived access. Expected responses follow the existing schedule API conventions.
- [ ] Add `GET /api/workspaces/:workspaceId/products/:productId/print-revisions` to list `{ id, label, createdAt }` and `GET …/print-revisions/:revisionId` to read one normalized print snapshot. Validate identifiers and scope every query by both workspace and product. Return an empty list when no version exists. Stop on not found, malformed snapshot or lost access with localized feedback. Do not return the raw JSON, provenance, or author fields.
- [ ] Implement `parsePrintRevision(snapshot: unknown, productId: string): PrintRevisionSnapshot | null`, where `PrintRevisionSnapshot` contains saved product identity, a read-only `ScheduleTree`, saved targets, and eligible dependency edges. Normalize import payload shaped and clone shaped baselines separately where fields differ. Use the stored `disciplineIds`, `stageIds` and `activityIds` for legacy import rows where applicable, resolving stage matches by saved identity within the discipline. Permit deterministic snapshot-local keys for missing identity only when no edge depends on them. Preserve saved `actualStageColors`, planned dates, and saved activity overrides. Derive stage bounds from the snapshot's activities where necessary using existing domain rules. Use established visual defaults for optional legacy colors. Never join to the living hierarchy for dates, names, colors or dependencies.
- [ ] Test an imported R00 and a cloned R00 with root activities, partial dates and dependencies. Verify the printed projection stays identical when living dates or colors differ. Reject invalid dates, wrong product identity and ambiguous required identity. Mark dangling or unsupported edges unavailable. Run the focused route, repository and adapter tests.

## 2. Add the dialog and resolve the print-only selection

**Files:** `src/SchedulePrintDialog.tsx`, `src/schedule-print-options.ts`, `src/ScheduleWorkspace.tsx`, `src/ExecutiveGanttFull.tsx`, `src/DatePickerField.tsx` only if integration needs a narrow fix, `src/locales/pt-BR.ts`, `src/styles.css`, and print dialog/caller tests.

- [x] Define `PrintOptions` with a resolved optional date interval, fit mode `automatic | width | single`, booleans for goals and today, and view-specific detail. Initialize the draft on open to the current product version or executive view, current hierarchy, complete period, automatic fit, goals and today on, dependencies off.
- [x] Reuse the existing modal/form and `DatePickerField` behavior. Verify initial focus, tab containment including the date picker popup, Escape, explicit cancel and focus return. Explain disabled saved-revision and dependency choices. Confirm only once per prepared document.
- [x] Add `visiblePrintRange(startDay, endDay, dayWidth, scrollLeft, plotWidth): PrintDateSegment | null` in the options module. Capture visible bounds when the dialog opens. For individual use the timeline's scrolling chart. For executive subtract the measured sticky hierarchy column from viewport width. Include partially visible edge days, treat the right pixel boundary as exclusive, and clamp to the displayed timeline. Disable visible range if the plot cannot be measured. Reusing the captured civil range with R00 does not change the interactive version or viewport.
- [x] Validate custom dates using the existing Brazilian civil date parsing and inclusive order. A valid interval with no dated bars still shows the selected hierarchy and its dates, with localized empty-window feedback where useful. Read the complete range from the selected schedule data without adding viewport padding or the current date. A visual toggle alone must not shift the chosen axis.
- [x] Reuse `visibleScheduleRows` and `visibleExecutiveFullRows` with print-only options. For current individual visibility, retain the live open states. The explicit full detail option includes all activities, including root activities. The two shallower choices omit activities while preserving aggregate dates. For unchanged executive detail preserve current filters and collapse state. An explicit detail override expands to the requested depth within the current filters and retains product-owned milestones. Keep the Products print representation when Products is selected.
- [x] Run dialog and caller tests for detail/date options, filtered executive views, collapsed defaults, cancellation, unavailable data controls, and the absence of schedule mutations or live view state changes.

## 3. Add fit modes and optional print overlays

**Files:** `src/PrintSchedule.tsx`, `src/print-pagination.ts`, `src/print-dialog.ts`, `src/SchedulePrintDialog.tsx`, `src/styles.css`, and print rendering/pagination tests.

- [x] Keep the current automatic planner as the default. Fit-width uses one date segment spanning the selected dates and the existing vertical row paginator. Keep nominal typography and space date ticks at readable intervals, preserving the first and last dates in the identification header. Test a range spanning multiple automatic date pages, a one-day range, and milestone-only intervals.
- [x] Fit-single uses one date span and one complete print surface. Keep long rows and dense overflow content in normal document flow before measuring. Measure that surface with the existing offscreen technique, compute `scale = min(1, availableWidth / width, availableHeight / height)`, then place the uniformly scaled surface inside the existing A3 content box. Size the final wrapper to the scaled footprint so Chrome creates exactly one sheet. Include the header, footer, legend, wrapped stage labels and overflow items in the measurement. Preserve all selected rows and marks.
- [x] Use measured fit and date label density to show a localized warning before launching native print. Add a second confirmation on a warned selection and discard the prepared output if options change or the user cancels. Retain the existing synchronous native handoff for the non-warning path as far as practical. Test that warning alone never invokes `window.print` and confirming the warning prints the same prepared selection.
- [x] Apply goal/milestone and today toggles to print marks, label bands and supplementary details. Preserve stage bars, marker ownership and the approved default geometry.
- [x] Run focused pagination/print tests covering sparse row/date combinations, scale warnings, oversize rows with dense milestones and abbreviation keys, and unavailable graphs. Assert normal automatic printing matches the approved structure and option changes do not touch interactive zoom, filtering, expansion or schedule records.

## 4. Regression, review and Chrome acceptance

- [x] Run `npm.cmd run lint`, `npm.cmd run typecheck`, `npm.cmd test -- --maxWorkers=4 --testTimeout=15000`, `npm.cmd run build`, and `git diff --check`. The longer test timeout covers the existing Windows PowerShell regression tests without changing repository defaults.
- [x] Obtain final independent whole-branch review using automatic routing. Focus on scope isolation, the visual defaults, and measurement/pagination consistency.
- [x] Keep the development server on port 5174. Compare default Multi 05 Beach with the accepted two-page individual v0.3 output and compare the accepted multi-product executive PDF for 60/340 mm columns, discipline lanes and product-owned milestones. In Chrome Save as PDF check the disabled controls, all modes, A3/10 mm margins, optional marks and warning confirmation. Include a tall schedule that prints on several automatic pages and fits to exactly one sheet with readable content accounted for. Manual acceptance passed on 2026-11-24; formal revisions and dependency printing are deferred.
- [x] Stop after manual acceptance. No merge or deployment is authorized.

Retain native execution and use automatic routing for the independent whole-branch review.
