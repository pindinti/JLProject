# 02 — Conceptual Data Model

This document defines domain entities and invariants, **not SQL DDL**. Codex must propose the actual PostgreSQL schema and migrations in the appropriate implementation phase.

## Logical structure

```text
Workspace
 ├─ Memberships (external identity + role + status)
 ├─ Products
 │   ├─ Product disciplines
 │   │   └─ Stages
 │   │       └─ Activities / tasks (stable identities)
 │   ├─ Schedule versions (R00, R01... / scenarios)
 │   │   ├─ Activity dates
 │   │   ├─ User-defined dependencies
 │   │   └─ Named target dates
 │   ├─ Audit operations and events
 │   └─ Imports (source metadata, report, external row identifiers)
 └─ Catalogs (discipline names, stage labels, palettes)
```

## Candidate entities

| Entity | Essential fields | Notes |
|---|---|---|
| `workspaces` | `id`, `name`, `created_at` | Company isolation; one workspace in MVP. |
| `memberships` | `id`, `workspace_id`, `auth_user_id`, `role`, `active` | `admin`, `editor`, `viewer`; do not infer permission from login alone. |
| `products` | `id`, `workspace_id`, `name`, `code`, `active_version_id`, `created_at` | Product may be a tower or development. |
| `disciplines` | `id`, `workspace_id`, `name`, `short_code`, `color`, `sort_order` | Editable reusable catalog. |
| `product_disciplines` | `id`, `product_id`, `discipline_id`, `sort_order` | Product-specific discipline assignment. |
| `stages` | `id`, `product_discipline_id`, `label`, `short_code`, `color`, `sort_order` | Stable groups; no independent schedule dates. |
| `activities` | `id`, `stage_id`, `source_external_id?`, `name`, `kind`, `notes`, `sort_order`, `archived_at?` | Stable task identity; deliverable revisions may be part of `name`. |
| `schedule_versions` | `id`, `product_id`, `label`, `kind`, `base_version_id?`, `status`, `created_by`, `created_at`, `published_at?` | `baseline`, `revision`, `scenario`; published snapshots immutable. |
| `activity_schedules` | `version_id`, `activity_id`, `start_date`, `end_date`, `duration_policy?` | Per-version civil dates and calendar behavior. |
| `dependencies` | `id`, `version_id`, `predecessor_kind/id`, `successor_kind/id`, `type`, `lag_value`, `lag_unit`, `created_by` | Stable task or stage endpoints, bound to version/scenario. |
| `milestones` | `id`, `product_id`, `name`, `sort_order`, `color` | Stable business target identity (rendered as `Meta`). |
| `milestone_schedules` | `version_id`, `milestone_id`, `target_date`, `operational_date?`, `notes?` | Versioned target dates; never auto-rescheduled. |
| `change_operations` | `id`, `version_id`, `actor_id`, `reason`, `source`, `created_at`, `before_version_token` | `manual`, `auto`, `import`, `publish`, `restore` operations. |
| `change_events` | `id`, `operation_id`, `entity_type/id`, `field`, `old_value`, `new_value`, `is_automatic` | Append-only before/after audit rows. |
| `import_batches` | `id`, `product_id`, `actor_id`, `filename`, `imported_at`, `checksum`, `report_json` | Store checksum/report, not raw sensitive XLSX by default. |
| `import_row_refs` | `import_batch_id`, `source_sheet`, `source_row`, `external_id`, `activity_id?`, `milestone_id?` | Traceability to source rows. |

The above is a **conceptual sketch**; PostgreSQL constraints, foreign keys, indexes, tenancy isolation, and performance choices remain to be designed.

## Phase 0C.2A authorization schema

`db/migrations/0001_workspace_authorization.sql` implements only `public.workspaces` and `public.workspace_memberships` on the isolated development branch. Both have UUID primary keys and UTC-capable creation timestamps. Membership has a foreign key to the workspace and to `neon_auth."user"`, one row per workspace/user pair, a checked `admin`/`editor`/`viewer` role, and an inactive default. A partial index supports active-membership lookup by authenticated user and workspace. Foreign keys restrict deletion so identity or workspace removal cannot silently orphan authorization records. There are no business-data tables in this phase.

## Phase 1A product schema

`db/migrations/0003_products.sql` introduces a stable product UUID and workspace foreign key. Names are required, trimmed, and unique per workspace without regard to case, including archived products; archived names cannot be silently reused. Description is optional and limited to 2,000 characters. `active` records archive state without deleting identity. `created_by` and `updated_by` reference managed user identities; UTC-capable creation and update timestamps and a monotonically increasing `version` support attribution and stale-edit rejection. A workspace/status/name index supports the product list. Future disciplines and schedule versions can reference the product UUID; `code` and `active_version_id` from the conceptual sketch are deferred until their semantics are approved.

## Phase 1B.1 schedule hierarchy

`db/migrations/0004_schedule_hierarchy.sql` adds `product_disciplines`, workspace-level `stage_definitions`, `discipline_stages`, and `stage_activities`. Each row has an opaque stable UUID. Composite foreign keys bind every child to the same workspace/product ancestry; deletes are restricted. Names and codes are configurable, with no seeded discipline or stage list. A shared stage definition supplies one code/color pair per workspace; a discipline stage supplies its own display name and order. The same code cannot acquire a different color in another discipline. `PL` is not hard-constrained to Architecture.

Activities have optional `source_external_id` reserved for import, with uniqueness within a product when present. It is not accepted from the Phase 1B.1 public API. Planned dates are PostgreSQL `date` values and may be both absent for a draft activity, or both valid with start no later than end. Stage dates are never stored: reads derive the minimum child start and maximum child end. Existing activity dates are protected by a database trigger that rejects updates until an audited date-edit operation is implemented. Metadata updates use a version token and cannot include date fields. The future immutable `R00` and scenario/version tables can reference the stable activity IDs without replacing them.

### Phase 1D.2A working-date audit

`db/migrations/0006_activity_date_audit.sql` adds `activity_date_changes` for one immutable event per actual working-date change. Its operation UUID is unique; composite foreign keys retain the full workspace/product/discipline/stage/activity scope and the actor's workspace membership. Each row stores a UTC instant, previous and new civil dates, mandatory reason, and before/after activity versions. An index supports newest-first activity history. An append-only trigger rejects updates and deletes. Deleting an audited activity or actor membership is restricted by foreign keys. The existing privileged database owner can still insert directly; migration `0007` therefore installs a limited Worker role that cannot mutate the audit table.

The controlled `change_activity_dates` function locks the active admin/editor membership and target activity, checks product status and expected version, and performs the working-date update and audit insertion in one PostgreSQL statement. A no-op creates no event or version increment. The date trigger accepts a changed date only while the no-login executor role runs that function; session settings alone cannot authorize an update. R00 remains an independent JSON snapshot protected by its existing mutation trigger. No target, unrelated activity, dependency, or schedule revision changes occur in this phase. Both migrations were separately approved for the development branch, and rollback-only synthetic database verification passed with the limited Worker role.

### Phase 1D.3 target management proposal

Migration `0008_target_management.sql` is prepared but has not been applied. It adds optional target description, selectable color, soft-delete timestamp, and version; user-created targets have nullable import identifiers while imported source identifiers and provenance remain unchanged. Active target names remain unique within a product. Updates and soft deletion are scoped to workspace/product and use optimistic versions. A target date change requires a reason and operation UUID and is written atomically to an append-only event table by the existing no-login date executor. Worker SQL cannot directly update `target_date` or write audit rows. R00 and import source references are unchanged. The workspace-local migration is waiting for explicit development-branch approval.

## Data integrity invariants

### Phase 1C.2 initial import schema

`db/migrations/0005_initial_import.sql` adds `business_targets`, `import_batches`, `import_source_rows`, and `initial_schedule_revisions`. Targets are product/workspace-scoped and retain both the official business date and optional operational date. Source references link each of the 46 source records and each of the five official target rows to its persisted activity or target. Import batches have workspace-scoped unique idempotency keys and normalized-source hashes. A product can have one initial R00 baseline; imported products also have one import batch, while manually cloned products have no import batch. The R00 JSON snapshot includes stable database IDs, source order/IDs, activity civil dates, target dates, actual shared stage colors, and an empty dependency array. A database trigger rejects R00 updates and deletes. The additive import migration was applied to the verified development branch after explicit approval.

### Phase 3A.2 product cloning

The additive `0011_product_cloning.sql` makes `initial_schedule_revisions.import_batch_id` nullable so a cloned product can receive its own immutable R00 without fabricated import provenance. The single PostgreSQL function copies the active working product hierarchy, active targets, planned dates, ordering, and colors in one statement transaction; it creates new product-specific IDs, references existing workspace-shared stage definitions, and resets creator metadata to the verified cloning actor. Import source IDs, source rows, audit history, soft-deleted targets, and dependencies are not copied. The source product and its R00 are unchanged. The function is workspace-scoped and checks active writer membership. Migration 0011 was applied to the verified JLProject development branch after explicit approval. Its initial table SHARE lock failed under the limited Worker role with SQLSTATE `42501`; approved migration 0012 replaced only the function body to remove that lock, without broadening grants. Worker hierarchy and target writes now lock their active product row before mutation. Read-only checks confirm Worker-only function EXECUTE and no R00 UPDATE/DELETE. The limited-Worker forced-failure transaction passed with no residue. A synthetic admin browser clone and read-only database verification passed: source and clone each contain 7 disciplines, 21 stages, 41 activities, and five active targets; schedule content matches; product-specific IDs are new; stage definitions are shared; no import provenance or audit events were copied; and the clone has one independent R00 with a null import batch and empty source metadata/dependencies. The source product and its import provenance match the pre-clone fingerprint.

1. Each product belongs to exactly one workspace; requests are scoped to an actively authorized membership.
2. An activity belongs to one stage, which belongs to a product discipline.
3. Each schedule version belongs to one product; its dates, dependencies, and targets cannot reference another product.
4. Use opaque stable IDs (UUID/ULID). Names and abbreviations are display values, not global primary keys.
5. Enforce `start_date <= end_date`. Store civil dates without time or timezone conversion.
6. A stage has no independent start/end fields: for a selected version, `start = MIN(child.start_date)` and `end = MAX(child.end_date)`.
7. Official business targets are separate from source Excel rows whose `Tipo` is `Meta`; avoid duplicates.
8. For MVP, dependencies cannot be self-referential, cyclic, or cross-product. Cross-**discipline** links within one product are allowed.
9. A scenario or revision created from an existing version gets an independent logical copy of its relevant date, target, dependency, and activity states, without mutating the parent.
10. Publication creates an independent immutable snapshot; working changes never modify a published revision in place.
11. Every schedule edit transaction commits adjusted dates and complete audit trail together, or rolls back together.
12. Check version/ETag/optimistic tokens to prevent lost updates; reject a stale preview and require revalidation.
13. Archiving/removing tasks must preserve referenced snapshots and audit history. Avoid physical deletion of historically referenced entities.

## Published revisions versus scenarios

- **`R00`**: immutable imported Excel baseline, with no dependencies.
- **Working copy**: editable state based on `R00`, with user-defined dates, dependencies, and targets; all edits audited.
- **Scenario**: isolated experiment derived from a specific version; never changes the official schedule automatically.
- **`R01`**: publication from a working state, with author, timestamp, and reason.
- **Restore**: publish a new revision using an older snapshot; never delete or overwrite later revisions.

**Implementation note:** audit events explain how a schedule changed. Versioned snapshots are the source of truth for rendering a chosen revision. Do not require full audit-log replay to build each Gantt.

## Calendars and durations

- Imported start and end civil dates are the source of truth for original schedules.
- Phase 3A.3A applied additive migration `0013_working_calendar.sql` once to JLProject Neon development for workspace calendar versions, active/soft-removed exceptions, and an append-only event ledger. Each event stores an operation UUID, actor UUID, UTC instant, workspace version, action, and complete before/after row state. A no-login executor owns the tables and controlled mutation function. The Worker reads these tables but cannot write them directly. One function call locks the workspace, rechecks active admin membership and expected calendar version, changes one exception, advances the version, and appends an event atomically.
- Local holidays have a name, one ISO civil date, and municipality. Collective vacation and company shutdown records have inclusive start/end dates and a description. All configured local exceptions apply to the workspace calendar; municipality is descriptive because products currently have no municipality assignment. Active local holidays are unique by workspace, municipality, and date. Removal preserves the row and all events.
- Built-in national and federal optional rules live in a separate deterministic source catalog. The reviewed 2026 federal optional-day list is complete after the October amendment; later years need a reviewed annual ordinance and are visibly marked unverified. Saturdays and Sundays are always non-working. Partial federal optional days count as whole non-working dates under JLProject policy.
- Calendar rules currently support 2026–2100. Earlier years are excluded because the present-day national holiday list would misclassify historical dates under earlier laws.
- Phase 3A.3B.1 adds a pure inclusive working-day end-date calculation. A working start date counts as day one; a non-working start begins on the next working date. The result lists skipped civil dates and all overlapping reasons, and identifies years without a verified federal optional-day catalog. It uses UTC arithmetic and does not persist or modify activity dates.
- Dependency propagation and automatic schedule recalculation remain deferred. Any working-day plan must use the selected calendar version and deterministic rule catalog, not the browser locale or an external runtime holiday API.
- Phase 3A.3B.2 introduces explicit activity planning metadata: `planning_mode` (`manual` by default or `working_days`), nullable `working_day_duration`, and nullable `planning_calendar_version`. Existing and imported rows retain manual mode with no inferred duration. Working-day create/edit requests are recalculated by the Worker using the active workspace calendar, then the database function rechecks the calendar version while holding a workspace lock before committing. Calendar edits do not rewrite saved dates. Existing date changes continue through the audited operation and require a justification. Migrations `0014`–`0016` are applied to development.
- Phase 3A.3C.1 reads working-day plans whose saved calendar version differs from the current workspace version. It calculates a proposed end from each saved start and duration, classifies date changes versus version-only changes, and returns skipped dates and optional-day coverage warnings. It does not update the activity, its calendar version, audit history, or R00. Manual and imported activities have no automatic proposal.
- A one-day marker may use the same start/end date. Corporate target dates are separate entities.
- Changing a calendar must never retroactively rewrite stored dates without an explicit previewed and authorized operation.

## Read-model examples

- **Detailed Gantt:** join selected `schedule_versions` / `activity_schedules` with activities, stages, and disciplines and render expandable groups.
- **Portfolio Gantt:** for each product choose its official or selected version, group activities by discipline/stage, calculate min/max dates, and pack overlapping intervals into visual lanes without modifying data.
- **Revision comparison:** join by stable IDs and detect inserted/removed activities, date differences, target differences, and dependency changes.
