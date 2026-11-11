# Phase 3A.6c.2 Root Activity UI Smoke Test

## Scope

Run this procedure only in the verified JLProject Development environment. Use a dedicated synthetic workspace and product created for the smoke test. Do not open, edit, or delete an existing business product. Do not use production.

The procedure checks the product schedule UI against the already deployed root activity API and data model. It does not apply migrations or publish schedule revisions.

## Setup

1. Confirm the app is configured for JLProject Development and the expected development branch.
2. Create a synthetic workspace/product and synthetic admin, editor, and viewer accounts, or use equivalent disposable Development fixtures.
3. Start the local application with `npm run dev` and sign in as the synthetic admin.
4. Open the synthetic product schedule. Start with no activities, then create one synthetic discipline, stage, and stage activity with dates so both hierarchy paths are visible.

## Checks

1. Confirm the product row has a discreet `Adicionar atividade` action. Add a root activity with manual dates and a custom HEX color. Confirm it appears directly under the product, before disciplines, with no artificial discipline or stage row.
2. Confirm the root activity's table row and Gantt bar align. Check the default root color `#8D9A89`, then the custom color. Change zoom, scroll the timeline, and select the row/bar; confirm the activity stays aligned and the schedule extent includes its dates.
3. Edit the root activity's name, planning mode, dates, duration, and color. Confirm working-day planning shows its calendar preview and requires a reason when dates or planning change. Use `Restaurar cor padrão`, save, and confirm the bar returns to `#8D9A89`.
4. Open the root activity history from its row. Confirm its activity-scoped history view loads. In a separate synthetic working-day root activity, update the Development calendar fixture and confirm the root activity appears in the calendar impact preview and can be selected for rescheduling.
5. Confirm the root activity can be soft-deleted through the existing preview and confirmation flow. Use a synthetic activity only; verify its history and R00 remain available through the product history interface.
6. Sign in as the synthetic editor and confirm the same write controls work. Sign in as the synthetic viewer and confirm the rows, Gantt, milestone interactions, and history remain readable while create, edit, date-save, and delete actions are absent.
7. Confirm the original stage activity and milestone still appear with their original dates and colors. Confirm the product's R00 snapshot remains unchanged.

## Cleanup

Remove or retain the synthetic workspace/product according to Development fixture policy. Do not promote these fixtures to a shared or production environment.
