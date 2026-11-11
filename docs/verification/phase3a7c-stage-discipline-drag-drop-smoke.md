# Phase 3A.7c Development browser smoke test

## Scope and preconditions

- Run only in the verified JLProject Neon Development branch and browser environment. Use a disposable synthetic product; stop if one is unavailable. Do not use a real product or confidential schedule.
- Use admin, editor, and viewer accounts. Keep a second editor tab open for the stale-order check.
- The fixture should include two disciplines, multiple stages (including an empty destination discipline), a stage with multiple activities, explicit and inherited activity colors, planned dates, durations/planning metadata, a milestone, date-history records, movement history, and the existing R00.
- Record IDs, discipline/stage/activity parentage and sibling order, dates, durations/planning metadata, colors, milestone values, audit counts, and R00 fingerprint before testing.

## Stage movement and ordering

1. As admin or editor, open only the synthetic product. Confirm table and Gantt rows align and note zoom, horizontal scroll, and expanded rows.
2. Drag one stage above another in the same discipline. Confirm the insertion indicator, then verify the changed order appears only after the server succeeds and reloads.
3. Drag a stage below another stage in the same discipline. Confirm the final sibling order and stable stage/activity IDs.
4. Drag a populated stage onto a different discipline, including the empty destination discipline. Verify the append indicator, the stage and descendants move together after confirmation, and the activity dates, planning data, and color overrides remain unchanged.
5. Use the stage handle by keyboard. Choose a destination discipline and beginning/end position, submit, and verify the move uses the same controlled endpoint. Confirm Escape dismisses the dialog and returns focus to the handle.

## Discipline movement and authorization

1. Drag a discipline before and after another discipline. Confirm before/after insertion indicators and the resulting product discipline order.
2. Use the discipline handle by keyboard to move a discipline to the beginning and end of the product list.
3. As viewer, confirm stage and discipline move handles are absent and no movement control is available.
4. While a pending synthetic move is unresolved, attempt a second submission and confirm only one request is sent.
5. In the second editor tab, reorder or move a sibling. Attempt a move from the first tab's stale order and confirm the stale response is shown without displaying the submitted order as saved.
6. Inspect a synthetic move request: it must be `POST /api/workspaces/{workspaceId}/products/{productId}/hierarchy/moves` with item kind/ID, loaded version, destination IDs/index, and complete source/destination sibling lists. It must not include client-supplied actor or role data.

## History, preservation, and final checks

1. Open **Ver log de alterações** and verify each stage move and discipline reorder appears once with actor, timestamp, item name/type, original/new hierarchy, and previous/new one-based position. Confirm no per-sibling event spam.
2. Confirm activity-specific history includes a moved ancestor stage and existing direct activity movement events.
3. Reload and compare all recorded IDs, dates, durations/planning metadata, explicit overrides, inherited colors, milestones, date-history records, movement audit counts, and R00 fingerprint. Confirm no formal revision was created.
4. Confirm table/Gantt row alignment, expansion, zoom, horizontal scroll, calendar bands, selection, and existing edit/history controls still work.
5. Restore the initial order only through the approved movement UI or discard/archive only the disposable synthetic product through its approved Development workflow. Never clean up with direct SQL.

Record date, Development branch, synthetic product identifier, tested roles, scenarios passed/failed, and browser-specific drag limitations. Do not include credentials or confidential schedule data.
