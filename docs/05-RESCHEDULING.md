# 05 — Dependencies and Minimum-Change Rescheduling

## Objective

Use Microsoft Project as a reference for scheduling semantics while making dependency setup intuitive and applying the **minimum necessary changes**. Dependencies must be created by users inside JLProject, **never inferred from the legacy workbook**.

## Nodes and edges

- An **activity** is a leaf node with start and end civil dates.
- A **stage** is a group node whose schedule boundaries are calculated from its child activities.
- Each dependency connects a predecessor to a successor. Either endpoint may be a task or stage. MVP does not permit cross-product dependencies.
- Cross-**discipline** dependencies within one product are valid.
- A task or stage may have multiple predecessors and successors.
- Store relationship type, optional lag, author, and associated version/scenario.

## Microsoft Project-style relationship types

| Internal code | Portuguese UI label | Constraint on successor B relative to predecessor A |
|---|---|---|
| FS / TI | `Término–Início` | B starts after A finishes, respecting calendar and lag. |
| SS / II | `Início–Início` | B cannot start before A starts plus lag. |
| FF / TT | `Término–Término` | B cannot finish before A finishes plus lag. |
| SF / IT | `Início–Término` | B cannot finish before A starts plus lag. |

**FS is the default.** In an inclusive, date-only calendar, FS with zero lag means **the first permitted workday after the predecessor's end** when using a business-day calendar.

**Lag:** working days by default in the initial phase. Negative lag / lead is out of the first supported release until validated with real business cases. Activate advanced types only after their tests cover exact semantics.

## Stage semantics

- `stage.start = MIN(child activity starts)`; `stage.end = MAX(child activity ends)`.
- **Predecessor stage:** its finish corresponds to the latest applicable child activity finish.
- **Successor stage:** if the constraint requires its start to move, shift the entire group of child tasks while preserving their relative offsets/durations, unless additional constraints require extra moves.
- **Successor activity:** shift only that task and any subsequently affected dependents.
- **Direct stage editing:** convert a requested group move to child-activity date changes shown in a preview. Resizing a stage's end requires explicitly selecting/editing its terminal child rather than silently writing a phantom stage date.
- Reject a dependency between a stage and one of its descendants, or any direct/indirect cycle after expanding groups.
- A stage without dated activities has no temporal boundaries and cannot serve as a timed dependency endpoint.

## Core rule: move as little as necessary

**A date edit affects only dependent activities whose constraints would otherwise be violated.**

- No dependencies: change only the explicitly edited activity.
- If a successor already satisfies a constraint on its current dates, **leave it unchanged**.
- Otherwise move it forward to the **earliest allowed position that is no earlier than its existing position**. Preserve its duration using the configured calendar; group shifts preserve internal offsets as far as additional constraints allow.
- Process affected successors in topological order, recursively.
- With multiple predecessors, respect the most restrictive bound applicable to the successor.
- **Never move successors earlier automatically** when predecessors finish earlier. Deliberate schedule optimization may be a separate future operation.
- Targets are fixed reference dates, not movable graph successors; warn if the revised schedule crosses a target.
- Use an optimistic version token in previews. Revalidate on save; reject stale previews rather than committing outdated results.

### Example: change only impacted activities

Simplifying calendar: consecutive calendar days without holidays, for demonstration only.

| Item | Original dates | After editing A | Why |
|---|---|---|---|
| A: ARQ·EC | Nov 02–12 | Nov 02–18 | Manual date edit. |
| B: ARQ·EP | Nov 13–20 | Nov 19–26 | B depends on A via FS. |
| C: ARQ·AP | Nov 21–Dec 04 | Nov 27–Dec 10 | C depends on B via FS. |
| D: PAI·EC | Nov 10–24 | **Unchanged** | Not affected by the dependency graph. |
| E: LUM·AP | Nov 18–Dec 08 | **Unchanged** | Not affected by the dependency graph. |

If B already starts on November 25, moving A's end to November 18 must **not** move B. Similarly, moving A's end earlier must **not** pull B earlier automatically.

## Calendar behavior

- Phase 3A.3A defines weekends, reviewed federal calendar rules, and workspace exceptions as non-working dates. Phase 3A.3B.1 adds a pure inclusive start-plus-working-days calculation that returns skipped-date reasons; years without a verified optional-day catalog are flagged in the result. This engine performs no persistence or activity-date updates. Dependency propagation and schedule mutations still require later review before use.
- Phase 3A.3B.2 adds an activity planning choice between manual dates and start-plus-working-days. The Worker recalculates the end date from the current workspace calendar for every working-day write and rejects a stale calendar version. A preview lists skipped dates and reasons; unverified nationwide optional-holiday years are visibly warned. Manual/imported activities remain manual and receive no inferred duration. Calendar edits never recalculate saved activities. Existing date changes retain the mandatory reason and immutable date-audit operation. Migration 0014 is awaiting development approval.
- Imported dates are preserved exactly even if they occur on Sunday, especially business targets.
- Business-day rescheduling must preserve the number of working days in an inclusive activity span. Do not treat a date-only day as a 24-hour timestamp subject to timezone shifts.
- Calendar changes require an explicit operation and impact preview; never silently rewrite old schedules.

## Date-edit workflow

1. User edits an activity start/end date or explicitly moves a stage.
2. Require a non-empty reason. Example Portuguese business note: `Reprovado pela diretoria em 12/11/2026; novo parecer em 18/11`.
3. A deterministic pure engine calculates the impact preview **without database writes**.
4. Show manually changed tasks, automatically rescheduled tasks, before/after dates, shift lengths, and breached goals.
5. User confirms or cancels. On confirmation, a single transaction stores all dates and all audit events under the same `operation_id` and `reason`.
6. On a concurrent edit, reject the stale preview; recalculate and request a new confirmation.

## Creating a new dependency

- Check user authorization and ensure both endpoints belong to the same product and version.
- Reject self-reference, ancestor/descendant loops, and cycles in the expanded dependency graph.
- If dates already satisfy the new constraint, save the dependency without shifting dates.
- If the constraint is violated, preview the minimum required rescheduling **before** saving the dependency.
- Deleting a dependency must not pull any successors earlier automatically.
- A new link in a scenario must not modify the official published revision until explicit publication.

## Error conditions

Dependency cycles; self-links; cross-product references; empty undated stages; activities without dates where timing is required; undefined calendar interactions; locked tasks that would need movement; out-of-range results; stale optimistic version tokens. Any error must leave both dates and audit records unchanged.

## Tests required before release

1. No links → only the manually edited task moves.
2. FS chain A→B→C shifts only necessary successors, preserving durations; independent D remains unchanged.
3. Existing successor slack is respected.
4. Multiple predecessors yield the most restrictive bound.
5. An earlier predecessor finish does not automatically move successors earlier.
6. Cross-discipline and task→stage, stage→task, stage→stage dependencies work consistently.
7. Separate SS, FF, SF cases; FS across weekends; fixed targets breached by rescheduling.
8. Cycles are rejected; failures roll back the full transaction.
9. One auditable operation groups all manual/automatic before/after events.
