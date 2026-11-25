# Phase 1 Schedule Printing Visual Corrections

**Status:** Completed and accepted in Production. The approved individual v0.3 and multi-product executive Products prints remain the visual regression baselines. See the [final acceptance checklist](../../14-SCHEDULE-PRINTING.md#final-production-acceptance).

**Specification:** [Schedule printing](../../14-SCHEDULE-PRINTING.md#phase-1-visual-correction)

**Goal:** Make the existing native Chrome print output readable and compact on A3, with Multi 05 Beach as the first acceptance case.

**Approach:** Keep the shared print component, print dialog, and pagination helpers. A fixed CSS adjustment would improve typography but leave the row/date page multiplication, while fully automatic browser pagination would surrender control over repeated context and two-dimensional page numbering. Use the existing explicit page model and derive its limits from the printable dimensions and actual print layout.

**Implementation record:** The print sheet uses a fixed 10 mm internal inset with a zero CSS page margin. This gives the layout one owner for insets and leaves the physical result to be measured in Chrome. The default date range comes from the selected data, independent of the interactive viewport. Row and label budgets use fixed typography and conservative wrapping estimates. The independent review led to explicit pages for dense executive bars, dated milestone references, and colored notes for narrow bars.

**Second Chrome review:** Multi 05 Beach improved from ten sheets to four. The follow-up replaces estimated row charges with measurements from the offscreen print layout, including repeated furniture and milestone labels. Conservative estimates remain as a fallback when layout measurements are unavailable. The follow-up also compacts and links milestone lanes, labels short edge months and `Hoje`, renames the hierarchy column, and uses flat bars with a solid or dotted date-source mark. The final page count and label readability remain for native Chrome acceptance.

**Individual approval and executive follow-up:** Multi 05 Beach v0.3 fits two sheets and is visually approved. Keep that print path unchanged. The executive Products view retains the existing lanes and selects the longest unambiguous stage label that fits the physical bar. `src/print-stage-labels.ts` tries full names, stage codes, discipline abbreviations, connected callouts in lane gaps, then numbered leaders with a compact per-product key. The tests cover overlapping products, repeated stage codes and colors, dense references, custom abbreviations, filter preservation, and the separate undated line. Executive label density and readability still require manual Chrome acceptance.

**Executive Products revision:** The approved follow-up uses a 60 mm product column and 340 mm dated plot. The interactive packer runs separately for each discipline in schedule order. Compact labels have a single identity across continuation pages. Available space governs whether text is printed inside a bar, connected as a callout, or resolved by a numbered key. The page paginator reserves space for the deduplicated abbreviation key. The product date summary, numbered key, and undated details stay outside the plot. The individual print v0.3 layout keeps its original columns and measured pagination.

**Multi-product milestone review:** The executive projection requires product ownership for each target and has no global target type. The print projection attaches targets to the owning product row. Their label band counts toward row height, their guides stop at the owning plot, and milestone-only date intervals retain their product. Exceptionally dense overflow is paginated under the product name. Physical stage continuations retain guides and print the milestone names only on the first slice. The print formatter continues to use supplied stage codes such as EX and PEX.

**Final manual acceptance:** The user visually approved individual v0.3 (Multi 05 Beach, two A3 landscape sheets) and the latest multi-product executive print with owned milestone guides. Both are the baseline for default printing in Phase 2. This was manual Chrome acceptance, separate from the automated tests and independent code review.

## 1. Establish the page box and typography

**Files:** `src/styles.css`, `src/PrintSchedule.tsx`, `src/locales/pt-BR.ts`, `tests/PrintSchedule.test.tsx`.

- [x] Use the same selected Multi 05 Beach range and hierarchy for baseline and comparison. Record Chrome paper, scale, margin, and header/footer settings. Inspect the resulting 420 × 297 mm PDF and measure all four insets. The existing named `@page` already declares 10 mm, so distinguish a Chrome override from a mismatch between the page wrapper and content box.
- [x] Use one inset mechanism. Prefer the named `@page` margin if verified in Chrome. Size the inner layout to the resulting 400 × 277 mm box, account for borders and padding, and remove overflow clipping as a way of concealing pagination errors. If Chrome overrides the named inset under the supported settings, use an explicit 10 mm internal inset with a zero CSS page margin and verify that the insets do not stack.
- [x] Trial dedicated `Hierarquia`, `Início`, and `Fim` columns with wrapped 9 pt names and 8 pt dates. Keep dates on one line and the hierarchy readable at the deepest selected level. Keep these columns if the remaining timeline width passes the monthly label check. Strengthen hierarchy through indentation, weight, and neutral fills. Verify that custom color swatches, bars, and markers remain visible.

## 2. Size date intervals and pack rows

**Files:** `src/print-pagination.ts`, `src/PrintSchedule.tsx`, `src/styles.css`, `tests/print-pagination.test.ts`.

- [x] Replace the fixed 365-day cut with a capacity derived from timeline width and the spacing required by 8 pt monthly labels. Try compact, unambiguous month/year labels such as `MM/AAAA`. Prefer a single interval when it fits. Otherwise partition the inclusive range into contiguous, reasonably balanced intervals and carry one physical width per civil day through all intervals. Use the same positioning for month ticks, grid lines, bars, and event markers. Clip any bar at the actual interval boundary and leave unused tail width if needed to maintain scale.
- [x] Choose rows for each date interval, then paginate vertically. Include intersecting rows and their visible ancestors. Show one-sided dates at their boundary. Include undated or otherwise unplotted selected rows once, in their original hierarchy order, so sparse pages can be removed without losing information. Retain selected dates in the printed columns and preserve necessary context for collapsed groups.
- [x] Replace the fixed 30-unit cap and character-count estimate with the available height after actual header, footer, and label lane space. Use the rendered fixed-width print layout to obtain wrapped row heights if CSS cannot guarantee the estimate. Reserve room for repeated ancestor context and keep each visible parent with its first visible descendant chain. Move that small group together at the boundary. Verify resulting pages fit without split or clipped rows.
- [x] Cover a single-day range, a partial last interval at the same day scale, sparse rows with undated and one-sided dates, long labels, nested parent boundaries, and a schedule overflowing in both dimensions. Assert complete selected-row/date coverage and no redundant empty schedule sheets.

## 3. Put names on the timeline and identify the schedule

**Files:** `src/PrintSchedule.tsx`, `src/styles.css`, `src/ScheduleWorkspace.tsx`, `src/ExecutiveGanttFull.tsx`, `src/locales/pt-BR.ts`, print component and caller tests.

- [x] Lay out event names in lanes above the chart, next to their marker positions. Reuse the approach in `src/design/gantt-colors.ts` where it fits. Its viewport-oriented width estimates and lack of wrapping should not govern print geometry. Use the print column width and wrapped label sizes, stack overlaps deterministically, and link displaced names to their colored lines. Include the lane heights in Task 2's row budget. Replace the unconditional milestone sheets with a linked overflow fallback only when a dense interval cannot accommodate its full labels and readable schedule rows.
- [x] Supply `Cronograma ativo` for the current product workspace and use an actual revision/scenario label wherever the caller already has one. Keep executive filter context, approved logo, issue date, footer, and page count. Keep caller changes limited to print data and copy.
- [x] Cover collocated events, long names near both margins, duplicate labels, dense overflow, and preservation of dates and colors. Verify full names and identifiers are present without tooltips and ordinary density creates no milestone-only sheets. Retain the existing caller coverage for visible selections and read-only behavior.

## 4. Verify and return for visual acceptance

- [x] Run the focused Vitest suites for print pagination, print rendering, and both callers. Run `npm.cmd run lint`, `npm.cmd run typecheck`, `npm.cmd test`, and `npm.cmd run build` when the corrections are implemented.
- [x] Repeat native Chrome Save as PDF for Multi 05 Beach with the baseline selections. Record schedule versus fallback page counts, measured page dimensions and insets, and whether 9 pt names and 8 pt dates remain readable. Aim for two or three sheets and record the constraint if the benchmark needs more.
- [x] Check an executive schedule with active filters and collapsed rows and a fixture exceeding both dimensions. Inspect the short final date interval, repeated identification and headings, second-axis page order, milestone collisions, custom colors, and the physical inset. Confirm printing only uses the authorized view data and issues no mutation calls.
- [x] Use the already selected native execution workflow with a final independent whole-branch review after implementation. Return the PDF observations for human visual acceptance before starting Phase 2. Keep the work in this Orca worktree.
