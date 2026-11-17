# Full Executive Gantt — Phase D

The read-only `/produtos/cronograma-executivo` route uses the authenticated Phase B projection for the selected workspace. It opens from the Home action, supports direct navigation, and returns to Home. Opening an individual product schedule from the full view records the return destination in browser history; returning to the portfolio remounts and refreshes the projection. Direct entry to the full route does not request the separate product-card list.

## Hierarchy and timeline

`visibleExecutiveFullRows` is a pure projection from the API hierarchy. It preserves product, discipline, stage, and activity IDs and order. The default Produtos level shows one row per product with dynamically packed, individually discoverable overlapping stages. Disciplinas stops at discipline rows. Etapas includes product, discipline, and stage rows. Atividades adds stage activities and product-root activities directly under their products. Product-root activities influence product date ranges at every level but never masquerade as stages. A missing interval produces no invented bar; a single known boundary produces a partial marker. The four detail levels do not change the separate day/week/month zoom, which opens at Mês.

The timeline uses the existing ISO civil-date and non-working-day utilities. Dates display in `pt-BR`. Product names and the two-level calendar header remain sticky while the chart scrolls. Product rows include milestone diamonds; same-day targets form a focusable cluster with their names, original dates, configured colors, optional descriptions, and optional operational dates in a detail dialog. Stage and activity colors remain unchanged. The current-day line and row hover/selection span the chart and hierarchy label.

## Data, security, and limitations

The Worker continues to authorize the workspace and execute the existing five scoped, set-based queries in a read-only transaction. The only additive response field is nullable `targets[].description`, read from the existing `business_targets.description` column. No migration or write API is involved. Filters, collapse state, and zoom run in memory after the authorized projection is received. A workspace change invalidates the previous view before new data can render.

The full view renders visible rows directly. Very large portfolios may benefit from row virtualization after representative performance measurements. Product-level stage lanes intentionally grow to show every overlap, independent of the compact Home's fixed 80 px height. Visual approval remains a separate review step.
