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

## Data integrity invariants

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
- Calculate displayed duration from the product calendar. Provisional default: Monday–Friday, no additional holidays; confirm with the business user.
- A one-day marker may use the same start/end date. Corporate target dates are separate entities.
- Changing a calendar must never retroactively rewrite stored dates without an explicit previewed and authorized operation.

## Read-model examples

- **Detailed Gantt:** join selected `schedule_versions` / `activity_schedules` with activities, stages, and disciplines and render expandable groups.
- **Portfolio Gantt:** for each product choose its official or selected version, group activities by discipline/stage, calculate min/max dates, and pack overlapping intervals into visual lanes without modifying data.
- **Revision comparison:** join by stable IDs and detect inserted/removed activities, date differences, target differences, and dependency changes.
