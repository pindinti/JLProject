# Phase 3A.7b Development browser smoke test

## Scope and preconditions

- Run only in the verified JLProject Neon Development branch and browser environment.
- Use a disposable, synthetic product fixture created for this verification. Do not use a real product or confidential schedule. If a suitable synthetic fixture is unavailable, stop and arrange an approved Development-only fixture before running this procedure.
- Use one active admin or editor account and one active viewer account. Keep a second browser tab signed in as the same editor for the stale-order check.
- The fixture should contain two disciplines, at least two non-empty stages, one empty stage, two activities in one stage, at least two root activities, and one activity with an explicit color override. Include null color overrides, a milestone, a date-history record, and the product's existing R00.
- Record the synthetic activity IDs, parents, sibling order, planned dates, durations/planning modes, override values, inherited colors, milestone values, date-history count, movement-history count, and R00 fingerprint before testing.

## Activity movement and ordering

1. Sign in as admin or editor and open only the synthetic product. Confirm the table and Gantt rows align before starting.
2. Drag the second activity in the populated stage above the first. Confirm the insertion line appears, the activity moves only after the request succeeds, and the stage order matches after refresh.
3. Drag an activity below another activity in that stage. Confirm the resulting sibling order and stable IDs after refresh.
4. Move an activity from a stage in one discipline to a stage in the other discipline. Repeat into the empty stage. Confirm both targets show an append indicator and refresh displays the correct parent.
5. Move a stage activity to the product root. Reorder root activities before and after one another. Move a root activity into a stage and back to the root.
6. Move the root activities into stages until the root is empty. Start another activity drag and confirm the product row visibly accepts the drop. Move an activity into the empty root and verify the resulting root order.
7. Use the handle by keyboard: focus it, press Enter or Space, choose a stage/root and beginning/end in the dialog, submit, then verify the same movement endpoint is used. Confirm Escape closes the dialog and restores focus to the handle.
8. Drop an activity over a discipline row and confirm the operation is rejected without a movement request.

## Authorization and conflict handling

1. Sign in as viewer. Confirm activity move handles are absent and the schedule remains read-only.
2. In the editor's second tab, perform a move that changes one of the first tab's sibling lists. Return to the first tab and attempt a move using its stale schedule. Confirm the server returns a conflict, the UI reports that the schedule changed, and no stale order is displayed as saved.
3. While a synthetic move request is pending, attempt to submit again. Confirm only one request is sent.
4. If the approved browser test environment supports a safe permission transition, revoke or switch the editor's membership before a move and confirm the denied response is shown. Do not alter roles on a real workspace.
5. In browser developer tools, inspect the move request. Confirm it is `POST /api/workspaces/{workspaceId}/products/{productId}/hierarchy/moves` and includes `kind`, `targetId`, `expectedVersion`, `destinationDisciplineId`, `destinationStageId`, `destinationIndex`, `expectedSourceOrder`, and `expectedDestinationOrder`. Confirm it does not contain a client-supplied actor or workspace role.

## Preservation and final checks

1. Reload the synthetic product and compare the recorded activity IDs, dates, durations/planning modes, and explicit color overrides. Confirm the moved activities retain their IDs and dates.
2. Confirm null overrides render using the destination stage color or product-root fallback, while explicit overrides retain their saved color.
3. Confirm milestones, activity date-history records, and R00 remain unchanged. Use the approved read-only Development audit inspection method to confirm successful moves appended movement events whose actor, timestamp, before/after parents, and positions match the actions. Confirm no formal schedule revision was created; do not write or repair audit rows during this check.
4. Confirm table and Gantt row keys still align, and check scroll position, zoom, calendar bands, selection, expansion, date history, and edit controls remain usable.
5. Leave the synthetic fixture in its recorded initial order if that can be done through the approved UI. Otherwise archive/discard only the disposable synthetic product through its approved Development workflow. Never clean up by direct SQL for this smoke test.

Record the date, environment, user roles, synthetic product identifier, scenarios passed/failed, and any browser-specific drag limitation. Do not include credentials or confidential schedule data in the report.
