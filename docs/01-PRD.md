# 01 — Product Requirements Document (MVP)

**Product:** JLProject  
**Specification version:** 0.2 — November 6, 2026  
**Status:** pre-implementation reference; unconfirmed assumptions are tracked in doc 08.

## Problem statement

The current planning process relies on complex Excel schedules. Dependencies are difficult to configure and understand, and maintaining several product schedules in parallel is cumbersome. We need a secure shared system that imports existing work without re-entry, shows concurrent disciplines and stages, tracks every schedule change, and allows safe what-if simulations.

## Users and authorization roles

- **Administrator (`admin`):** manages memberships, products, reusable catalogs and settings; may also edit schedules and publish official revisions.
- **Editor (`editor`):** creates and edits products, activities, milestones, dependencies and scenarios, and imports schedules; publication permissions are policy-controlled (MVP default: admin only).
- **Viewer (`viewer`):** reads permitted schedules and audit history and can export accessible data; cannot modify it.
- Start with one company workspace, while designing entities for workspace isolation in the future.
- Authenticate every user session and associate access with a valid active workspace membership. All changes identify actor and timestamp.

## Domain hierarchy

`Product → Discipline → Stage → Activity/task`.

Example disciplines (source names are in Portuguese): `Arquitetura`, `Paisagismo`, `Luminotécnico`, `Comunicação Visual`, `Imagens de Venda`, `Maquete`, `Garagem`. The list must be configurable; allow import aliases and per-product selection.

Observed stages: `EC`, `EP`, `AP`, `PL`, `MV`, `Pré-executivo`, `Executivo`, `Lanç.`. They vary by discipline and are not a hard-coded global sequence. `PL` should be architecture-only in the default template, not through an inflexible database constraint.

Activities have a name, optional kind (`Análise`, `Acompanhamento`, `Validação`, `Marco`, or Other), start and end dates, notes, sorting order, and parent stage. Preserve `R00` / `R01` when present in an activity's **source title**; they refer to deliverable revisions, not schedule revisions.

**Stages are groups.** Stage start/end are computed from child activity dates; a stage must not hold a second independent set of dates. A stage-level move becomes a visible, reviewed adjustment of its child activities. Empty stages and undated draft activities need safe, explicit display states.

## Required MVP features

### F01 — Sign-in and access control

Email/password sign-in, email verification and password recovery, membership approval, administrator/editor/viewer roles. Secure all API operations, imports and exports. The entire user-visible authentication flow is `pt-BR`.

### F02 — Product scheduling

Create/edit products, included disciplines, stages, activities, and named target dates. Support start/end dates, calendar-based calculated duration, stable ordering, filters and search. Reject end dates earlier than start dates.

### F03 — Detailed product Gantt

Expandable discipline → stage → activity tree, activity table on the left, and true calendar timeline on the right. Daily/weekly/monthly zoom; display simultaneous bars faithfully. Clicking a bar opens activity and dependency details.

### F04 — Consolidated portfolio Gantt

Exactly **one logical row per product**. The row contains as many internal visual lanes as necessary to show *every* `Discipline · Stage` bar, even when they overlap in time. Each bar spans the earliest start and latest end among that stage's activities. Clicking a bar opens its stage in the detailed Gantt. Filters, zoom, and color-by-stage/color-by-discipline options.

### F05 — Configurable target dates

Any number of named targets with dates, initially per product. Render as vertical markers at the exact date. In the portfolio view, a product target marker must be restricted to that product's logical row (not drawn across unrelated products). Do not shift target dates automatically. Highlight schedule conflicts with relevant targets. Portfolio-wide targets are a possible later enhancement.

### F06 — Excel import

Support `.xlsx` with mapping, validation, preview, import report, and explicit confirmation in one transaction. Operational activities and original start/end dates are the critical data. For the reference workbook, obtain five business targets from `Metas e Premissas`, and **discard the entire legacy `Predecessora` column**. Import no dependencies or inferred links. Preserve the source dates and task ordering; create immutable original revision `R00`.

### F07 — Excel export

Export a selected version with product, discipline, stage, activity, kind, start/end, calculated duration, notes, goals, and revision metadata. Prioritize a reliable structured workbook over pixel-perfect reproduction of the legacy template. Protect exported text from spreadsheet formula injection. User-facing workbook labels should use `pt-BR`.

### F08 — Date change history

Changing a date requires a non-empty reason. Record actor, UTC timestamp, changed field, old value, new value, reason, version, and operation ID. Automatically propagated changes link to the initiating operation. Audit data is append-only and visible to authorized users. A rejection (e.g. `Reprovado pela diretoria em 12/11/2026`) is **reason text**, not a dedicated approval status or workflow.

### F09 — User-configured dependencies

Select a predecessor from a searchable picker organized by discipline and stage. Allow multiple predecessors and links between tasks/stages, including across disciplines of the same product. Support Finish–Start (FS/TI), Start–Start (SS/II), Finish–Finish (FF/TT), Start–Finish (SF/IT), with FS as default; optional lag. Prevent cycles. **Only dependencies explicitly created or confirmed within JLProject drive rescheduling.**

### F10 — Minimum-change rescheduling

When a date changes, move only downstream activities that violate newly applicable dependency constraints. Preserve unaffected dates, existing duration, and the configured calendar. Preview impacts before saving; commit dates and audit changes atomically. Never automatically move successors earlier. With zero dependencies, only the edited activity changes.

### F11 — Revisions and scenarios

Keep the original imported `R00` immutable. Support independent draft scenarios, preview and comparison of date/goal/dependency differences, and controlled publication of new immutable revisions (`R01`, `R02`, ...). Restoring a historical revision creates another revision, never deletes intermediate history.

## Explicitly out of scope for MVP

- Formal approval/rejection workflows, opinions and digital signatures.
- Email/WhatsApp notifications and third-party integrations.
- Project budgeting, resource allocation, time sheets, and MS Project resource leveling.
- Arbitrary-depth nested tasks, advanced critical path, automated resource optimization.
- File attachments and real-time collaborative document editing.
- Importing or reverse-engineering legacy Excel predecessor relationships.
- Drawing dependency connectors by mouse drag (possible after the searchable picker works).

## Non-functional requirements

- Responsive web app, **desktop-first for Gantt**, with usable basic mobile reading.
- Entire user-visible UI in `pt-BR` (see doc 09), with `DD/MM/YYYY` date presentation.
- Support tens of products and thousands of activities with pagination/virtualization where needed.
- Private code repository, authenticated API, server-side authorization, no privileged credentials in frontend.
- **Schedule dates are civil dates** (`YYYY-MM-DD`), without timezone offsets; audit timestamps are UTC.
- Optimistic concurrency, atomic import/edit operations, and recovery from failures.
- Tested independent backups and exports before using real business data.
- Initial hosting cost target of zero within free tiers; never trade off security for a free quota.

## MVP success criteria

1. Import Multi 05 Beach as **41 operational activities and five business targets**, preserving all dates and creating **zero dependencies**.
2. Show every overlapping stage correctly in the consolidated Gantt.
3. Edit a date with a reason and inspect before/after audit history.
4. Add a cross-discipline dependency with an intuitive picker and see only necessary downstream dates move.
5. Test a scenario without affecting the published schedule.
6. Demonstrate role isolation with two real authenticated users.
7. Verify that all application labels, messages and exports are Brazilian Portuguese, while engineering documentation remains English.
