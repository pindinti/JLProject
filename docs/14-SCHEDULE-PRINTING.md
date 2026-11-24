# Schedule Printing Specification

## Goal

Provide management-ready, read-only printing for individual product schedules and consolidated executive schedules. Users can print on paper or save as PDF through the native browser print dialog.

## Phase 1

- Use a dedicated printable representation, separate from interactive Gantt markup and independent of viewport size, scroll position, and interactive zoom.
- Default to A3 landscape with 10 mm margins. Use the approved `/brand/jlproject-logo.svg` in the document identification area.
- Include product or executive schedule identification, revision/scenario identification where applicable, issue date, footer, and page numbering.
- Reuse current domain schedule data, row visibility, timeline/date calculations, design tokens, custom activity/stage colors, goals and milestones.
- Print individual schedules using the currently selected revision/scenario, hierarchy visibility, and explicit date bounds. Print consolidated schedules using current filters and expanded/collapsed rows.
- Print milestone names visibly; do not rely on interactive tooltips.
- Continue rows vertically as needed. Fit the selected timeline to one A3 page width when monthly resolution is readable. For longer timelines, paginate across date intervals with one document-wide temporal scale. Repeat document identification, hierarchy columns, timeline headers, and page numbering on continuation pages. Avoid splitting rows or orphaning parent headings; do not force entire hierarchy branches together.
- Printing must not call schedule mutation APIs or change schedule data.
- All user-facing print UI and content use Brazilian Portuguese and `DD/MM/YYYY` dates.

### Phase 1 visual correction

**Manual acceptance recorded:** The user visually approved both Phase 1 layouts in Chrome Save as PDF. Individual v0.3 prints Multi 05 Beach on two A3 sheets, with readable dates and labels, usable pagination, and integrated milestones. The latest multi-product Executive Products PDF preserves the 60 mm product column, 340 mm plot, discipline order and lanes, compact labels, colors, and supplementary keys. Product milestones appear in their owner's row, with guides restricted to that plot. Keep both layouts as visual regression baselines. This record reflects the user's review. It does not imply an automated PDF comparison.

- Use the 400 × 277 mm content box inside A3 landscape, with one owner for the 10 mm inset. Verify effective margins on all four edges of the actual Chrome PDF at normal scale. Keep headers, footers, names, and markers inside the inset.
- Use 9 pt activity labels and 8 pt row dates at normal scale, with dedicated `Cronograma`, `Início`, and `Fim` columns. Wrap long names. Differentiate hierarchy levels through indentation, weight, and subtle row styling. Use flat bars with configured colors and retain the planned versus derived date-source distinction.
- Keep one width for the entire selected range when monthly labels fit. On horizontal continuations, use the same physical width per civil day and position the grid, bars, and markers from the same scale, including on the final interval. Omit redundant empty date/row combinations. Keep intersecting rows, one-sided dates, undated rows, and required ancestor context represented in the document. Maintain the selected range and relative row order.
- The current screens have no separate print range selector. The default is the range of the selected dated rows, packed bars, and visible events. Interactive padding and the current date do not extend this range. If an explicit print range is supplied, respect it.
- Place full milestone and goal names near their colored vertical markers in timeline label lanes. Keep same-date markers and long names distinguishable through stacked lanes, wrapping, or linked callouts. Reserve room before paginating rows. A linked spill section is a fallback for exceptional density when the names cannot fit with readable schedule rows.
- Measure the laid-out print rows, document headings, and milestone labels before opening native print. Use the measured height when packing vertical pages and keep compact milestone lanes linked to their timeline guides. Label partial edge months and show a discreet `Hoje` when the current date is in the interval.
- In the executive Products view, use a restrained 60 mm product column with start and end dates under the name. Give the remaining 340 mm to the timeline. Plot only discipline/stage bars and partial-date markers. Keep their exact positions, durations, colors, and date-source distinctions.
- Keep one logical row per product. Group internal lanes in the product's discipline order and reuse the interactive stage packer within each discipline. Additional lanes handle interval or label conflicts. Use no spacer lanes. Continue a physically oversized product on another numbered sheet with its identity and scale intact.
- Use one compact label per stage throughout the document, such as `ARQ · EP`. Use the stage name when its code is ambiguous within the product. Prefer inline labels, then connected callouts in free space, and reserve numbered references for remaining collisions. Keep milestone guides clear of visible labels and reference leaders.
- Use presentation-only discipline abbreviations (ARQ, PAIS, LUM, CV, IMG, MAQ, GAR for the corresponding standard disciplines). Disambiguate custom abbreviations within the document and deduplicate the key per sheet. Place the key, reference details, and undated stages outside the timeline plot. Give undated stages no marker or invented date.
- In the executive printout, place milestone names and dates inside the owning product row and restrict milestone guides to that plot. Product ownership and milestone identity come from the existing domain data. Matching names and dates do not merge distinct milestones. Include milestone-only date intervals in pagination and budget the label band with its owning row. The current executive model defines no global milestones.
- Identify individual prints as `Cronograma ativo` for the living schedule or use the actual selected revision/scenario label when available. Use the executive identification and current filter context for consolidated prints.
- Aim for two or three A3 pages for Multi 05 Beach. Treat this as a benchmark with the same selections and Chrome settings. When the content requires more pages, preserve every selected item and the reading sizes.

## Phase 2 approved scope

- The existing print action opens a compact Brazilian Portuguese dialog using existing form, dialog and date-picker patterns. Confirm hands the prepared document to native browser printing. Cancel, Escape and closing leave the schedule and preferences unchanged. The dialog needs no persisted preferences, custom preview or PDF engine.
- Individual printing defaults to the currently selected, authorized version. The current product screen supplies the living schedule. The repository stores immutable R00 baselines, but the frontend has no authorized snapshot reader, and the user excluded new endpoints for printing. This phase therefore displays the living schedule and explains why saved revisions are unavailable. A future version selector may offer actual authorized snapshots without assuming a fixed revision label. Never reconstruct historical facts from living rows.
- Individual hierarchy options are current visibility, disciplines/stages/activities, disciplines/stages, and disciplines only. Executive options reuse Products, Disciplines, Stages and Activities. Default to the existing executive detail, filters and expansion state, including the approved Products representation. Changes in the dialog apply only to the print document.
- Date range options are complete schedule period (default), visible period, and custom inclusive civil dates. Capture the visible civil-day bounds from the invoking timeline, independent of the eventual print geometry. Reject invalid or inverted dates. Clip visual bars and markers to the selected interval, preserve actual date values in printed columns and retain the selected hierarchy and undated rows.
- Scaling options are automatic (default, equivalent to Phase 1), fit timeline width with vertical continuation, and fit the entire selected document to one A3 sheet. Keep 10 mm margins. Preserve all selected content. Warn in Brazilian Portuguese before printing when essential text would fall below 7 pt or date resolution is compromised. The warning allows printing to proceed. The 7 pt threshold does not change the approved default typography.
- Goals and milestones and the current-date indicator default to enabled. Preserve executive milestone ownership. The frontend has no authorized graph for the living schedule or executive projection, and it cannot read cloned snapshots. The dependency option is disabled with a localized explanation.
- Printing stays read-only, with no new endpoints, schema, data migration, dependencies, or permission changes. Default printing remains visually equivalent to accepted Phase 1 output.

### Phase 2 manual acceptance

On 2026-11-24, the user confirmed that all supported print configuration features passed manual functional and visual acceptance in Chrome. Coverage includes hierarchy detail, complete/visible/custom date ranges, all three scaling modes and the readability-warning proceed path, optional milestones and current-date indicator, executive filters and product-owned milestones, cancellation, and read-only behavior. The accepted Phase 1 individual and executive PDFs remain visual regression baselines. Saved revisions and dependency lines remain unavailable and are shown as disabled options with explanations.

### Deferred backlog

- **Formal revision printing:** Offer only saved revisions that actually exist and read each immutable snapshot through an authorized path. Preserve R00 immutability; never reconstruct historical schedule values from the living schedule. This requires separate approval for any new read API, database access, or authorization change.
- **Dependency printing:** Enable dependency lines only when the selected representation and revision have an existing authorized graph in frontend state. Keep the option disabled with a pt-BR explanation until that is available. Do not weaken authorization or add print-only access in this phase.

## Acceptance

- Browser print preview supports physical printing and Save as PDF without new dependencies.
- Both schedule types preserve hierarchy, Gantt bars, custom colors, goals, milestones, and relevant dates.
- A3 landscape pages have 10 mm margins and remain readable across horizontal and vertical continuation pages, including schedules exceeding both dimensions.
- Continuation pages retain document identification, hierarchy columns, timeline headers, footer, and page numbering.
- Individual/executive selections match their approved current state, and printing leaves schedule data unchanged.
- Phase 2 validates the available version, unavailable revision and dependency controls, each hierarchy option, complete/visible/custom dates, invalid and empty periods, horizontal and vertical continuations, width and single-sheet fitting, readability warnings, optional overlays, executive filters and ownership, cancellation, and both approved Phase 1 baselines. Printing actual snapshots remains contingent on an existing authorized reader.
