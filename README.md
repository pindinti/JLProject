# JLProject

**Product and discipline schedule management** — English-language reference documentation for incremental development with Codex in VS Code.

- **Specification:** v0.2 — November 6, 2026; implementation through Phase 1D.1.1.
- **Application UI locale:** Brazilian Portuguese (`pt-BR`) only.
- **Documentation/prompt language:** English only.
- **Initial users:** the product-development team of a Brazilian company.
- **Existing schedules:** Excel workbooks, imported without their legacy dependency relationships.
- **Goal:** portfolio visibility, schedule control, traceable date changes, safe schedule simulations, and secure multi-user access.

## Getting started

1. Read `AGENTS.md` for permanent instructions and the required language split.
2. Read `docs/01-PRD.md` for product behavior and scope.
3. Read `docs/02-DATA-MODEL.md` for entities, versions, and invariants.
4. Read `docs/03-EXCEL-IMPORT.md` for the verified Multi 05 Beach workbook mapping.
5. Read `docs/04-GANTT-UX.md` and `docs/05-RESCHEDULING.md` for visualizations and dependencies.
6. Read `docs/06-ARCHITECTURE-AND-SECURITY.md`, `docs/07-DELIVERY-PLAN.md`, `docs/08-TESTS-AND-DECISIONS.md`, and `docs/09-LOCALIZATION.md`.
7. Use `CODEX-PHASE-0-PROMPT.md` in the first VS Code Codex conversation. Do not skip the Phase 0 approval gate.

## Approved product decisions

- Hierarchy: **Product → Discipline → Stage → Activity/task**.
- Detailed Gantt for one product; consolidated portfolio Gantt with **one logical row per product** and every discipline/stage bar, including time overlaps.
- Consistent colors by discipline or stage, user-selectable.
- Unlimited named target dates displayed as vertical Gantt markers.
- Import and export `.xlsx`. **Ignore all legacy `Predecessora` values at import time.**
- Every date change requires a reason and an audit history, including automatic downstream moves.
- Users later create dependencies from a searchable activity/stage picker, including cross-discipline and multiple-predecessor links.
- Automatic **minimum-necessary forward** rescheduling; impact preview before saving; never automatically pull unaffected dates forward.
- Immutable published revisions; isolated working scenarios; comparison and non-destructive restoration.
- Multiple users, password-based authentication, and server-side role/workspace authorization.

## Important distinctions

- A rejection is a **textual date-change reason**, not a separate approval workflow.
- `R00` / `R01` inside a source activity name is a **deliverable revision**, not a JLProject schedule revision.
- Source `Predecessora` values are **not trustworthy**, must **not** be imported, analyzed, or reverse-engineered.
- Git branches version source code; JLProject scenarios and revisions version **schedule data** in the database.
- Technical terminology in the documentation is English; source Excel labels and user-facing business labels remain in Portuguese.

## Recommended repository organization

Keep these Markdown files at the root and in `docs/` of the future private repository. Implement only the currently approved phase. Do not include the real spreadsheet in git, public fixtures, telemetry, logs, or production deploys. Keep the workbook local and ignored by version control; this documentation contains structural import details only.

## Candidate official technical references

- Cloudflare React + Vite Workers: https://developers.cloudflare.com/workers/framework-guides/web-apps/react/
- Cloudflare Static Assets limits: https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/
- Cloudflare and Neon: https://developers.cloudflare.com/workers/databases/third-party-integrations/neon/
- Neon Auth: https://neon.com/docs/auth/overview
- GitHub Pages usage limits: https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits

> Revalidate providers, library licenses, free-tier limits, and current support at implementation time. Free-tier eligibility is not a security or uptime guarantee.

## Phase 0A local development

Phase 0A provides only the local React/Vite/Cloudflare Workers foundation. It does not include authentication, database connectivity, business data, Excel import, Gantt views, or scheduling behavior.

### Prerequisites

- Node.js 24 or a currently supported Node.js LTS release.
- npm 11 or a compatible package manager.

### Setup

```powershell
npm install
```

Do not add secrets to this repository. `.env.example` and `.dev.vars.example` are intentionally empty configuration templates. `.env`, `.dev.vars`, and Excel workbooks are ignored by Git.

### Commands

```powershell
npm run dev
npm run lint
npm run typecheck
npm run test
npm run build
```

`npm run dev` starts the Vite server with the Cloudflare Vite plugin. The root page displays the Portuguese foundation shell. `GET /api/health` is routed to the Worker and returns the non-sensitive payload `{ "status": "ok" }`.

### Project boundaries

- `src/` contains browser-facing React code and centralized `pt-BR` strings.
- `worker/` contains server-side Cloudflare Worker API code.
- `domain/` is reserved for framework-independent schedule logic.
- `db/migrations/` contains reviewed, manually applied database migrations.
- `tests/` contains automated frontend and Worker tests.

## Phase 0B Neon development setup

Phase 0B connects the Worker runtime to the isolated Neon `development` branch for JLProject. It does not create business tables, enable direct browser database access, or implement application authentication.

### Local Worker configuration

1. Authenticate through the Neon CLI browser flow. Never provide credentials in chat.
2. Link the repository to the intended project and development branch without automatic environment pulling:

```powershell
npx neon@latest link --project-id <project-id> --branch development --no-env-pull --no-config --yes
```

3. Pull only PostgreSQL variables into the ignored Worker configuration file:

```powershell
npx neon@latest env pull --file .dev.vars --service postgres
```

4. Ensure `.dev.vars` includes `JLPROJECT_ENV=development`.

`.dev.vars` and `.neon` are ignored by Git. `DATABASE_URL` is read exclusively by Worker code; it must never be prefixed with `VITE_`, imported by `src/`, committed, or logged.

### Connectivity verification

With `npm run dev` running locally, request:

```powershell
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:5173/api/internal/database-connectivity
```

The development-only check runs `SELECT 1 AS ok` through `@neondatabase/serverless` and returns only a generic status. It is unavailable outside `JLPROJECT_ENV=development`. `GET /api/health` remains independent of database connectivity and returns `{ "status": "ok" }`.

## Phase 0C.1 local authentication

Managed Better Auth is enabled on the JLProject Neon `development` branch. Keep the repository linked to that branch. The development branch is configured for email/password sign-in, required email verification, disabled public sign-up, and session revocation after password reset. Accounts are created by an administrator in Neon; creating an identity never grants JLProject workspace access.

Confirm the selected branch and obtain its public Auth Base URL with `npx neon@latest status` and `npx neon@latest neon-auth status`. Check that the project is JLProject and the branch is `development` before copying any URL.

1. Copy `.env.example` to `.env.local` and set `VITE_NEON_AUTH_URL` to the **public** Auth Base URL for the development branch. This URL is intentionally visible to browser code; it is not a database connection string.
2. Copy `.dev.vars.example` to `.dev.vars` if needed. Preserve the Phase 0B Worker-only `DATABASE_URL` and `JLPROJECT_ENV=development`, and set `NEON_AUTH_BASE_URL` to the same development Auth Base URL. Never use a `VITE_` prefix for database credentials.
3. Run `npm install` and `npm run dev`, then open `http://localhost:5173`.
4. For a development test identity, use the recovery link to set a password, verify the email when prompted, and sign in. The expected JLProject screen is **Acesso pendente** until Phase 0C.2 supplies active workspace membership.

The browser uses `@neon/auth` and provider-managed HttpOnly session cookies. It obtains a short-lived JWT with `getSession()` for calls to the same-origin Worker API. The Worker verifies the JWT using Neon's public JWKS, then denies workspace access by default. `GET /api/auth/session` returns a generic `401` for invalid credentials and `403` for a valid identity without membership. `GET /api/health` is still public.

The initial screen waits for provider session restoration and Worker verification. A temporary restoration or validation error shows a retry action instead of treating the user as signed out. The Worker allows five seconds of `iat` clock drift from the provider but never relaxes JWT expiry.

Run `npm run lint`, `npm run typecheck`, `npm run test`, and `npm run build` before review. The test suite mocks provider flows and signs local test JWTs; it does not by itself prove email delivery or live session revocation. See `docs/06-ARCHITECTURE-AND-SECURITY.md` for remaining security limits.

## Phase 0C.2A development workspace authorization

The Worker verifies the Neon JWT, then reads active workspace membership from PostgreSQL for every protected request. The `admin`, `editor`, and `viewer` roles are stored in the development database. No signup or valid identity automatically creates membership. `GET /api/workspaces/:workspaceId/membership` returns only the workspace UUID and role to an active member. `GET /api/auth/session` continues to return `403` and the access-pending state until an active membership exists. Both routes use `Cache-Control: no-store`.

The additive migration is `db/migrations/0001_workspace_authorization.sql`. It was applied only to the linked JLProject `development` branch. For a fresh development branch, confirm the project and branch before applying it:

```powershell
npx neon@latest status
npx neon@latest psql development --project-id rapid-mud-63974868 -- -v ON_ERROR_STOP=1 -f db/migrations/0001_workspace_authorization.sql
```

Apply each migration once. Do not run the bootstrap template as part of migration automation. To create the **first** development administrator, a human administrator must:

1. Confirm that the Neon project is JLProject and the branch is `development`.
2. Verify the intended identity and its UUID in Neon Auth, including email verification. Do not select by email pattern or signup order.
3. Review `db/bootstrap-development-admin.sql.example`, replace its two placeholders in a private local copy, and execute it manually against `development` only.
4. Confirm that it returns exactly one `workspace_id` and `admin` role. Zero rows means no authorization was granted; investigate the identity or existing workspace before retrying.

The bootstrap is never executed by the application or tests. The first development-only bootstrap was explicitly approved and executed manually in Phase 0C.2A.1, creating one `JLProject` workspace and one active admin membership for the verified test identity. A repeat run of the template inserts no rows when a workspace already exists. Save private SQL copies as UTF-8 without a byte-order mark for Neon's embedded psql, and keep them out of Git. Do not use this procedure in production.

## Phase 0C.2B revocation gate

The existing Neon JWT contains no documented session identifier, and the managed `get-session` endpoint did not return a session when called with only that JWT. A controlled replay remained authorized immediately after logout. The product owner accepts this bounded 15-minute JWT replay risk for the current internal MVP of approximately 2–3 users; immediate revocation is not implemented. Every protected business request must still verify current active workspace membership and role. Revisit revocation before broader production deployment. See decision D023 in `docs/08-TESTS-AND-DECISIONS.md`.

## Phase 0C.2C workspace administration

The active administrator can open **Administração → Usuários** after signing in. The page lists existing workspace memberships and allows confirmed role or active-status changes. It does not create users or memberships. The Worker checks the verified identity and current active admin membership for each request. PostgreSQL serializes changes per workspace and prevents removal of its last active administrator.

Apply the additive function migration once on a fresh JLProject development branch after verifying `npx neon@latest status` reports the correct project and `development` branch:

```powershell
npx neon@latest psql development --project-id rapid-mud-63974868 -- -v ON_ERROR_STOP=1 -f db/migrations/0002_membership_administration.sql
```

The current development branch already has this migration. Its application did not change the existing workspace or membership. The API routes are `GET /api/workspaces` (active memberships for the caller), `GET /api/workspaces/:workspaceId/memberships` (admin list), and `PATCH /api/workspaces/:workspaceId/memberships/:membershipId` (one `role` or boolean `active` field). Errors are in pt-BR and responses are not cached.

Neon's [managed Admin API](https://neon.com/docs/auth/guides/plugins/admin) requires an admin provider session and a password when creating a user. JLProject will not create or handle user passwords. Public signup remains disabled; account onboarding and membership creation require a separate reviewed flow. A live read-only check confirmed that the existing development administrator sees the active admin in **Administração → Usuários**. To repeat it, run `npm run dev`, sign in as that administrator, open **Administração**, then sign out. Do not exercise role or status changes on the real first-admin membership without separate approval. Automated tests cover the mutation HTTP path with isolated fakes; concurrent SQL mutation remains to be tested on disposable identities/workspaces before relying on it operationally.

## Phase 1A products

The **Produtos** page lists products in the current workspace. Administrators and editors may create, edit, and archive; viewers can only read. Archiving retains the product for future hierarchy references. Product names are unique per workspace without regard to case, including archived names. Edits and archive requests carry the current version to prevent stale overwrites. All product data remains behind Worker JWT and live membership checks; the browser never receives database credentials.

The additive migration is `db/migrations/0003_products.sql`. It was applied once to the JLProject `development` branch after explicit approval. On a fresh branch, confirm the project and branch before applying it:

```powershell
npx neon@latest status --output json --no-analytics
npx neon@latest psql development --project-id rapid-mud-63974868 -- -v ON_ERROR_STOP=1 -f db/migrations/0003_products.sql
```

Routes: `GET` and `POST /api/workspaces/:workspaceId/products`; `GET` and `PATCH /api/workspaces/:workspaceId/products/:productId`; `POST /api/workspaces/:workspaceId/products/:productId/archive`. The create body is `{ "name": "...", "description": "..." }`; update adds a positive `version`, and archive supplies `{ "version": 1 }`. The API uses generic Portuguese errors and `Cache-Control: no-store`. No products are inserted by migration. For local testing, run `npm run dev`, sign in with an authorized development account, and open **Produtos**. Use synthetic names only.

A live administrator browser test created one synthetic product and confirmed it remained listed and could be opened after reload. Read-only database verification found one active version-1 row with a creator identity. Role restrictions, edits, archive, duplicate handling, and stale versions were verified in automated tests; they have not been exercised with additional real development identities.

## Phase 1B.1 schedule hierarchy API

Migration `db/migrations/0004_schedule_hierarchy.sql` adds configurable product disciplines, shared workspace stage definitions, ordered discipline stages, and ordered activities. It was applied once to JLProject `development` after explicit approval and added no rows. Stage start/end are derived from activities; empty stages have null dates. Existing activity planned dates cannot be changed in this phase, including through direct SQL, because an audited date-edit operation is still required. Activity metadata can be updated with a version token.

All routes are nested under `/api/workspaces/:workspaceId/products/:productId`. `GET /hierarchy` returns the complete ordered tree. `GET`/`POST /disciplines` list/create disciplines; `PATCH /disciplines/:disciplineId` updates one. `GET`/`POST /disciplines/:disciplineId/stages` list/create stages; `PATCH /disciplines/:disciplineId/stages/:stageId` updates one. `GET`/`POST /disciplines/:disciplineId/stages/:stageId/activities` list/create activities; `PATCH /disciplines/:disciplineId/stages/:stageId/activities/:activityId` updates metadata only. All writes require admin/editor membership. Viewer access is read-only.

Before applying the additive migration to a fresh development branch, verify the linked project and branch. Apply only after explicit approval:

```powershell
npx neon@latest status --output json --no-analytics
npx neon@latest psql development --project-id rapid-mud-63974868 -- -v ON_ERROR_STOP=1 -f db/migrations/0004_schedule_hierarchy.sql
```

The synthetic integration check used the local Worker API with a signed-in development administrator. It created one discipline, an empty stage, a dated stage, and two activities under the synthetic Phase 1A product. The hierarchy returned display order and derived dates correctly; stale metadata edits and attempted date edits were rejected. The rollback-only database verification script checks stage aggregation, shared stage-code color, and the date trigger without retaining test mutations:

```powershell
npx neon@latest psql development --project-id rapid-mud-63974868 -- -v ON_ERROR_STOP=1 -f db/verification/phase1b1-development.sql
```

## Phase 1B.2 schedule editor

From Products, open a product and choose **Abrir cronograma**. The editor shows the ordered Product → Discipline → Stage → Activity hierarchy with collapsible groups, shared stage codes/colors, derived stage dates, and activity dates formatted as `DD/MM/YYYY`. Admins and editors can create and edit hierarchy metadata; viewers have read-only access. New activity dates are entered as `DD/MM/YYYY` and sent to the API as ISO civil dates. Existing activity dates remain read-only until an audited date-change operation is approved. Edits use version tokens and require confirmation. The editor does not delete rows or change scheduling relationships.

`GET /api/workspaces/:workspaceId/stage-definitions` is a read-only, workspace-scoped catalog for the stage selector. It uses the same Worker JWT and active-membership boundary as the hierarchy API. Stage creation can reuse a catalog entry or create a new workspace code/color through the existing stage-create endpoint. No new migration or seeded catalog is required for this phase.

A signed-in development administrator verified the UI with synthetic data: creating a discipline, stage, and dated activity, then reloading and seeing the hierarchy and Brazilian-formatted dates persist. This browser check supplements the automated API and component tests; viewer restrictions and concurrency conflicts were verified through automated tests.

## Phase 1C.1 local XLSX preview

Admin and editor members can open **Importar planilha** from Products and select a reference-format `.xlsx` file. The browser parses only `Cronograma Produto` and `Metas e Premissas`; raw workbook bytes are not sent to the Worker, stored in the database, or logged. The screen displays source counts, disciplines/stages/activities, original civil dates, official targets, and validation issues. Phase 1C.2 adds an explicit confirmation and a structured import request; no data is saved merely by selecting a file. The file can be replaced or canceled. Do not place the confidential reference workbook in this repository.

The preview uses `/produtos/importar` so it can survive page reloads. Window-focus session revalidation keeps the active screen mounted while validating; this is needed because closing the native file picker emits a focus event before the file selection is handled. A failed session check still changes the view through the existing authentication boundary.

The development administrator selected the confidential reference workbook locally and reported the expected 46 source records, 41 activities, five targets, seven disciplines, zero dependencies, and 21/10/2026–17/01/2028 source span. The parser reported no errors and three target-reconciliation warnings at source rows 15, 24, and 50. Phase 1C.2 proposes unique date-only matches for review; it never silently accepts them.

The lazy-loaded reader is `read-excel-file` 9.3.14 (MIT), with `fflate` 0.8.3 for archive preflight. The browser rejects files above 2 MB and archives with more than 100 entries, more than 8 MB in one entry, or more than 16 MB of declared expanded data. Source data is limited to rows 5–50; official targets to rows 4–8. The parser ignores predecessor, duration, and Gantt presentation columns entirely. Five `Meta` source rows are excluded from operational activities and reconciled against official targets. Ambiguous cases block persistence.

## Phase 1C.2 structured import

The admin/editor preview requires confirmation for each unique date-only `Meta` match, then shows a final confirmation before creating a **new** product. It sends normalized JSON to `POST /api/workspaces/:workspaceId/imports`; the Worker repeats all structural, date, count, ordering, and mapping checks and never accepts predecessor/dependency fields. The response contains the created product and immutable R00 identifiers. A retry with the same idempotency key returns the original result; the same source submitted under another key is rejected. Existing products are not overwritten.

For the reference workbook preview, the three date-only proposals keep **Confirmar importação** disabled until each is checked under **Correspondência das metas**. This section is immediately below validation and shows the remaining count. A blank product name, source validation error, unexpected reference count, or invalid normalized structure also blocks the action with a specific pt-BR explanation. Informational warnings do not block. Reviewing the preview and checking boxes does not save data; do not press the final import button for the confidential workbook without separate authorization.

The reference workbook has 20 stages containing operational activities and one stage containing only a source `Meta`. The preview retains that empty operational stage, making 21 discipline–stage combinations without turning the `Meta` into an activity. The structured import validator permits an empty stage only when a source `Meta` record belongs to it.

`db/migrations/0005_initial_import.sql` is additive and was applied once after explicit approval to the verified JLProject Neon `development` branch. It adds four tables and a single-call PostgreSQL import function. `db/verification/phase1c2-development.sql` is a rollback-only synthetic integrity check; it passed after migration, and a read-only count found zero rows in all four new tables. Do not run the migration again on this branch. Verify the project/branch before any database command:

```powershell
npx neon@latest status --output json --no-analytics
```

For a fresh development branch only, obtain separate migration approval, then apply it once and run the rollback-only check:

```powershell
npx neon@latest psql development --project-id rapid-mud-63974868 -- -v ON_ERROR_STOP=1 -f db/migrations/0005_initial_import.sql
npx neon@latest psql development --project-id rapid-mud-63974868 -- -v ON_ERROR_STOP=1 -f db/verification/phase1c2-development.sql
```

The actual confidential workbook must **not** be imported during development verification or without separate explicit authorization. Use only synthetic data for integration checks. The R00 snapshot does not implement later revisions, scheduling, or date-edit audit events.

After migration, a development administrator ran two simultaneous synthetic requests against the local Worker: one returned `201`, the other an idempotent `200`, both with `R00`. The authorized hierarchy read returned seven disciplines, 21 stages, and 41 activities. A read-only development query confirmed one import batch, one R00, five targets, 51 provenance references, an empty R00 dependency array, and distinct official/operational target dates. The hierarchy API does not return dependencies; those checks used the database. Targets are now available through a separate read-only endpoint. An unauthenticated import POST returned `401`. The confidential workbook was not submitted.

## Phase 1D.1 schedule workspace

Open a product in **Produtos** and choose **Abrir cronograma**. The schedule uses a full-viewport split workspace: a hierarchical table and date-aligned Gantt share one ordered visible-row model and one vertical scroll container. The divider starts at 50% and can be dragged or adjusted with the arrow keys. The timeline scrolls horizontally and offers day, week, and month zoom plus period navigation. Narrow screens switch between table and Gantt panes.

The Worker now serves `GET /api/workspaces/:workspaceId/products/:productId/targets` through the existing JWT, active-membership, workspace, and product checks. It returns only the product's named target dates in display order. Targets appear as vertical markers and are not activities. No migration, target edit, or imported-data change is part of this phase.

Admin and editor metadata forms open in a side panel while the schedule remains mounted. Existing activity dates remain read-only; audited date changes belong to a later phase. Viewer access remains read-only. The Gantt uses pure civil-date positioning in `domain/schedule-workspace.ts` and browser CSS; no Gantt library or scheduling engine was added.

### Phase 1D.1.1 Gantt navigation

The horizontal Gantt scrollbar remains visible in the workspace footer while the activity list scrolls vertically. The timeline header and chart follow that one scrollbar. A teal **Hoje** line uses the current `America/Sao_Paulo` calendar date, separate from dashed business targets. Click the timeline header or an empty chart cell to select an exact date; the selected column is highlighted and its `DD/MM/YYYY` date appears in the toolbar. Use arrow keys while the timeline header has focus to change the date, or **Limpar data selecionada** to clear it. Zoom and row expansion do not alter stored schedule dates.
