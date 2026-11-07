# JLProject

**Product and discipline schedule management** — English-language reference documentation for incremental development with Codex in VS Code.

- **Specification:** v0.2 — November 6, 2026; pre-implementation.
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
- `db/migrations/` is reserved for reviewed database migrations in a later approved phase.
- `tests/` contains automated frontend and Worker tests.
