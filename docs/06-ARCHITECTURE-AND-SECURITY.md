# 06 — Architecture and Security

## Candidate architecture (to be validated in Phase 0)

```text
Browser (React + TypeScript + Vite, pt-BR UI)
                    | HTTPS, same origin
                    v
Cloudflare Worker (Static Assets + HTTP API)
                    | authentication, authorization, validation, audit
                    v
Neon PostgreSQL (private database, versioned migrations)
                    ^
Managed identity provider candidate (Neon Auth / Better Auth)
```

**Recommendation:** use **Cloudflare Workers with static assets and an API served from the same origin**, rather than GitHub Pages for production. Keep source code in a private GitHub repository and deploy via integration. GitHub Pages is not intended as a generic commercial web-app backend, while Workers supports application assets and API together.

Cloudflare and Neon offer free tiers subject to CPU, storage, execution and request quotas. The **initial cost target is BRL 0/month, not a guarantee of free or permanent service**.

## Candidate stack

| Layer | Candidate | Notes |
|---|---|---|
| Frontend | React + TypeScript + Vite | Desktop-first interactive Gantt; check Gantt library licensing and performance. |
| Frontend hosting | Cloudflare Workers Static Assets | React/Vite integration officially documented. |
| API | Cloudflare Workers, TypeScript | Authenticate, authorize, validate, import, reschedule, audit. |
| Database | Neon PostgreSQL | Distinct development/production environments; version-controlled migrations. |
| DB access | `@neondatabase/serverless` or Hyperdrive | Secrets available only on server-side Worker bindings. |
| Authentication | Managed Neon Auth candidate | Email/password, secure sessions, recovery; workspace authorization remains application-controlled. |
| Excel | A maintained XLSX library compatible with Workers | Verify license, resource use, and maximum file size. |
| Testing | Unit, integration, E2E | Scheduling core should be deterministic and DB-independent for unit tests. |

## Phase 0B verified local database connectivity

- The local repository is linked to the verified JLProject Neon project and its isolated `development` branch. The `production` branch was not modified.
- `@neondatabase/serverless` is used only from `worker/database.ts`. Browser-facing `src/` code has no database driver or database environment variables.
- The Neon CLI writes PostgreSQL variables only to the Git-ignored Worker `.dev.vars` file. The local `.neon` context is also ignored. No connection strings belong in documentation, source, logs, or Vite variables.
- `GET /api/internal/database-connectivity` is available only when `JLPROJECT_ENV=development`. It executes `SELECT 1 AS ok`, returns only a generic status, sets `Cache-Control: no-store`, and suppresses database error details.
- `GET /api/health` remains a non-sensitive application-liveness response and does not depend on the database.
- Managed Better Auth configuration was not changed. Application authentication, authorization, migrations, and all business tables remain deferred.

## Authentication proof-of-concept checklist

- Check identity-provider session integration with same-origin SPA/API.
- Validate invitation/creation policy: **public sign-up must not automatically grant access to any corporate workspace**. If restricting sign-up is unavailable, deny every session without an approved membership and minimize public registration exposure.
- Verify email verification, password recovery, secure logout, revocation, and session expiry.
- Implement actual server-side roles and workspace scope; do not rely only on frontend conditional rendering.
- Audit authorship must link to the correct authenticated subject ID.
- Inspect free-tier limits, inactivity suspension, service availability, and exit strategy. If the selected provider fails enterprise requirements, propose an alternative before coding production authentication.

## Phase 0C.1 managed authentication boundary

- Neon Managed Better Auth was verified on the isolated JLProject `development` branch. Only that branch's configuration was updated: public sign-up disabled, email verification required, verification email on sign-in enabled, and sessions revoked on password reset. Production was not changed.
- `@neon/auth` is the browser client. Its public Auth Base URL is supplied as `VITE_NEON_AUTH_URL`; the same URL is supplied to the Worker as `NEON_AUTH_BASE_URL`. `DATABASE_URL` remains Worker-only. The browser never receives a privileged database connection.
- Neon retains the password and browser session. The browser uses the SDK with credentialed requests to the managed auth origin, then sends the short-lived `getSession().data.session.token` JWT to the same-origin Worker in a Bearer header. The JWT is kept in memory for that request and is not written to local storage or logged.
- `worker/auth.ts` validates the EdDSA signature against the development auth JWKS, issuer and audience against the auth origin, expiry, issue time, subject, verified email, and banned state. Token validation errors return a generic response. The Worker does not accept browser-provided role or user identity headers.
- `GET /api/auth/session` is the proof endpoint. It rejects cross-origin browser requests, uses `Cache-Control: no-store`, and returns only a generic status/error. Phase 0C.2A now requires an active database membership. `/api/health` remains public and independent of auth.
- The proof endpoint is read-only and uses a Bearer header, so it does not accept ambient cookies and has no cookie-based CSRF mutation. Future cookie-authenticated mutations need explicit CSRF protection and origin checks. Provider CORS/trusted origins and cookie attributes are managed in Neon; local `localhost` must be a trusted origin. Production origins and HTTPS must be configured and verified before deployment.
- Logout calls the managed provider and clears the UI state only on success. Offline JWT verification cannot detect immediate provider-side session revocation; a JWT already issued can remain cryptographically valid for at most 15 minutes after issuance. Decision D023 accepts this bounded risk for the current small internal MVP and requires reassessment before broader production deployment.
- Cross-site browser cookie restrictions, especially Safari tracking prevention, may affect session persistence. Verify supported browsers and the final hosting origin before production. The development test confirmed recovery email delivery, password setup, sign-in, JWT verification, and pending access. Email OTP delivery and live session revocation remain unverified integration gates.
- A live reload investigation found that Neon returned a session and JWT with the provider cookie present, but its JWT `iat` was one second ahead of the local Worker clock. The original zero-tolerance `maxTokenAge` check rejected that JWT. The Worker now permits at most five seconds of future `iat` drift while enforcing a strict `exp` check and a 15-minute maximum age. No token or cookie contents were logged; temporary diagnostic code was removed. The UI now waits for the provider and Worker checks and shows a retry state for temporary failures instead of treating them as confirmed logout.
- The development-browser acceptance sequence passed: sign-in, access-pending view, reload, close/reopen tab, logout, and reload to login. An unauthenticated Worker request returned `401`.

## Phase 0C.2A workspace authorization foundation

- `public.workspaces` and `public.workspace_memberships` were created only on the JLProject `development` branch with the reviewed additive migration `db/migrations/0001_workspace_authorization.sql`. Memberships reference both the workspace and `neon_auth."user"`, are unique per user/workspace, and default to inactive. Role values are constrained to `admin`, `editor`, and `viewer`. The active-user/workspace lookup has a partial index. No product or schedule tables were created.
- The Worker verifies the Neon JWT before using its subject as the database identity key. It reads the membership from PostgreSQL on each protected request. The permission matrix grants admin `read`/`edit`/`manage`, editor `read`/`edit`, and viewer `read`. Missing workspace, inactive membership, unsupported role, and ownership mismatch all deny access. Resource ownership checks are reusable but have no business-table caller in this phase.
- `GET /api/workspaces/:workspaceId/membership` is a non-sensitive proof route. It returns only the workspace UUID and database role after identity and active-membership checks. `GET /api/auth/session` reports access pending for a signed-in user without active membership. Both routes reject cross-origin browser requests, suppress details in errors, and disable caching. Client role or user headers are ignored.
- Bootstrap requires a human to verify a Neon Auth user UUID and manually execute `db/bootstrap-development-admin.sql.example` against development. The app never chooses an admin by email, signup order, or presence of a valid session. Phase 0C.2A initially left the development branch with zero workspaces and memberships.
- A live signed-in development user reached `Acesso pendente` after this migration and Worker change, confirming that a valid provider identity does not grant access without membership. A separate unauthenticated request to the membership endpoint returned `401`.
- Cloudflare's Vite plugin copies local `.dev.vars` into the Worker build output for `vite preview`; Cloudflare documents that this file is not deployed. The repository's `npm run build` removes those local secret files from `dist/worker` after bundling. `dist/` and `.dev.vars` remain Git-ignored, and the browser bundle has no database credential.

### Phase 0C.2A.1 first development administrator

- An explicit user approval authorized one manual bootstrap on the linked JLProject `development` branch. Before execution, an exact lookup matched one verified, unbanned development auth identity, and both authorization tables were empty. The prepared SQL was private and Git-ignored; no identity UUID or credential was printed in the report.
- The first execution attempt failed at a UTF-8 byte-order mark before `BEGIN`; a read-only count confirmed zero rows in both tables. After removing the marker, the transaction committed one `JLProject` workspace and one active `admin` membership. A read-only join confirmed exactly one workspace, one membership, and one intended active verified admin.
- The signed-in test user reloaded the local application and saw `Sessão autenticada`, confirming the live `/api/auth/session` authorization path. With the provider session, the workspace membership endpoint returned `200` and `admin` for the intended workspace and `403` for another workspace ID. A no-credential request to the same endpoint returned `401`. No token or cookie was copied into the report.
- A further signed-in reload retained `Sessão autenticada`; after `Sair` and another reload, the login screen returned. This verifies the browser's normal session/logout flow, not immediate revocation of a previously copied JWT.
- The template's `BEGIN`/`COMMIT`, workspace table lock, empty-table guard, and foreign keys make first creation atomic. A repeat run makes no changes because a workspace already exists. Unexpected existing workspace state returns zero inserted rows and requires manual review; no alternate user gains membership automatically.

### Revocation gate before business data

Neon documents the browser's managed, HttpOnly provider session separately from its short-lived JWT. The JWT can be verified offline from JWKS, but it does not carry a session identifier in the documented payload. **Inference:** a signed JWT already copied before logout or provider-side revocation can still pass the current Worker signature/claim checks until expiry (at most 15 minutes). Checking that some session exists for the same user would not prove that the presented JWT belongs to that session. Membership deactivation is read from the database on each request and therefore takes effect independently of JWT expiry, but it is not a substitute for provider revocation.

For the current internal MVP of approximately 2–3 users, the product owner has explicitly accepted this bounded replay window. This is a residual security risk, not immediate session revocation. Keep the 15-minute maximum JWT age and all signature/claim checks, and read active membership and role from PostgreSQL on every protected business request. Revisit and test a provider-supported immediate revocation mechanism before broader production deployment. A successful UI logout does not invalidate a previously issued JWT at the Worker boundary.

Sources: [Neon JWT guide](https://neon.com/docs/auth/guides/plugins/jwt), [Neon authentication flow](https://neon.com/docs/auth/authentication-flow).

### Phase 0C.2B revocation investigation: enforcement blocked

- The current Worker verifies the Neon JWT offline and then reads active workspace membership. Neon documents an opaque, HttpOnly provider session cookie separate from the 15-minute JWT. Logout, password-reset session revocation, and admin session revocation invalidate the provider session, but an already issued JWT remains independently verifiable until expiry. Expired JWTs are rejected by the existing Worker checks.
- The development JWT's claim **names** were inspected without logging values. They match the [documented JWT payload](https://neon.com/docs/auth/guides/plugins/jwt) and include no session ID, `sid`, or `jti`. The development `neon_auth.session` table has `id`, `token`, `userId`, and `expiresAt`, but the JWT provides no authenticated key linking it to one row. A query for any active session belonging to the same user would permit a revoked token to borrow another session's status.
- The managed instance's [OpenAPI schema](https://neon.com/docs/auth/guides/plugins/openapi) publishes `get-session`, but a controlled request with only the current JWT and no provider cookie returned HTTP `200` with both `session` and `user` absent. Thus its generic Bearer security declaration does not establish JWT-to-session introspection. The browser's cookie is scoped to the Neon auth origin and is not sent to the local Worker.
- A controlled development replay retained a JWT only inside one browser function, called the protected membership endpoint (`200`), signed out successfully through the Neon SDK, and called the same endpoint with that unchanged JWT immediately afterward. It still returned `200`. No JWT, cookie, or session identifier was printed or persisted. This is direct evidence that the current Worker does **not** meet immediate revocation acceptance; it is not evidence of a provider logout failure.
- The installed `@neon/auth/server` package provides a beta, framework-agnostic same-origin proxy toolkit. It would require changing auth routing and cookie handling. Its signed session-data cache has a positive TTL (default 300 seconds), so using the cache would delay revocation. Even with an uncached provider cookie check, the present JWT lacks a documented session binding, and a different active session of the same user could satisfy a user-only comparison. The [Next.js server SDK](https://neon.com/docs/auth/reference/nextjs-server) is documented, but is not a supported drop-in Cloudflare Worker session validator. Neon's [roadmap](https://neon.com/docs/auth/roadmap) marks standalone frontend/backend session sharing as coming soon.
- Phase 0C.2B did not change Worker authorization or managed auth configuration. Its immediate-revocation objective was not met. Decision D023 accepts the bounded delay for the current small internal MVP; the exact-session binding problem remains for the broader production review.
- Live provider validation would add at least one remote auth check, usually followed by a provider database read, to each protected Worker request. This adds latency and consumes Neon resources; caching reduces cost but creates a revocation window. Cloudflare's Free plan allows 50 external subrequests per invocation and does not separately bill subrequests; Neon currently lists Managed Better Auth in its Free plan up to 60,000 monthly active users. No per-check price or latency guarantee has been established. Sources: [Cloudflare limits](https://developers.cloudflare.com/workers/platform/limits/), [Cloudflare pricing](https://developers.cloudflare.com/workers/platform/pricing/), [Neon free-plan description](https://neon.com/blog/neon-free-plan-1-gb-per-project).

### Phase 0C.2 prerequisites

Apply active membership, role, and resource-scope checks to every future business-data request. Do not grant privileges based on email or a valid Neon identity alone. Verify provider trusted-origin configuration before loading confidential schedules. Reassess the accepted JWT replay window before broader production deployment.

### Phase 0C.2C membership administration

- `GET /api/workspaces` lists only the signed-in user's active workspace names, IDs, and database roles. `GET /api/workspaces/:workspaceId/memberships` lists member names, emails, roles, and active status only for active administrators of that workspace. `PATCH /api/workspaces/:workspaceId/memberships/:membershipId` accepts exactly one `role` or `active` field. All endpoints use verified JWT identity, same-origin browser checks, current database membership, and `Cache-Control: no-store`. The browser never submits an actor identity or trusted role claim.
- Migration `0002_membership_administration.sql` adds one `SECURITY INVOKER` function. It locks the workspace row, verifies the actor is still an active administrator, checks that the target membership belongs to that workspace, and applies one role/status change in the same transaction. It rejects demotion or deactivation of the last active administrator. Concurrent writers on one workspace serialize at the lock, so each checks the updated active-admin count. The function is not callable by the browser; Worker database credentials remain private.
- The administration page is available only after the Worker reports an active admin workspace. Its list and mutations remain server-authorized, including after a role change or deactivation. Errors do not reveal database details. Membership deactivation removes business access on the next protected request even while a previously issued JWT remains cryptographically valid.
- The migration was applied to the linked JLProject `development` branch. A read-only function lookup succeeded, and counts remained one workspace, one membership, and one active administrator. A signed-in administrator opened the local page and saw the existing active admin in the member list. No real member role/status was changed. Automated tests mock the repository; the SQL concurrency behavior has not yet been exercised with multiple administrators in a disposable database branch.
- The managed Auth SDK admin plugin requires provider-admin rights and a supplied password, so the application does not use it. Phase 1E uses Neon's supported branch-specific Auth Management API from server code and Neon-hosted password recovery. Public self-registration remains disabled. See the Phase 1E onboarding boundary below.

### Phase 1A product boundary

- Product routes remain under `/api/workspaces/:workspaceId/products`. The Worker verifies the provider JWT and reads active workspace membership for every request. `admin` and `editor` may write; `viewer` may only read. Every SQL statement filters by the authorized workspace ID; single-product lookups additionally filter by product ID. Cross-workspace IDs return no product data. Responses disable caching and errors do not expose database details.
- Creation records the verified actor. Edits and archive operations require the current product version and atomically increment it with `updated_by` and `updated_at`; stale or archived changes conflict. Archive is soft and preserves the product UUID for future hierarchy references. Product names are unique across active and archived rows within a workspace, case-insensitively. No product or schedule data is seeded by migration.
- The accepted 15-minute JWT replay window remains unchanged under D023. Active membership and role are still read from PostgreSQL on each protected product request. Before real confidential schedules are loaded, complete the other minimum security controls below, including backup/restore validation and audit design for schedule changes.
- The additive migration was applied after explicit approval to JLProject `development`; it created an empty products table and two application indexes in addition to the primary key. Local unauthenticated product access returned `401`. A signed-in administrator created one synthetic product and verified list/details persistence after reload. A read-only database check confirmed a single active, version-1 row with creator attribution. No production or confidential business data was touched.

### Phase 1B.1 schedule hierarchy boundary

- All hierarchy routes remain nested under an authorized workspace and product. The Worker verifies the provider JWT and an active workspace membership on each request. `admin`/`editor` may create or update; `viewer` reads only. The repository verifies product, discipline, and stage ancestry with workspace-scoped queries before child access. Composite foreign keys enforce the same ancestry in PostgreSQL. No hard-delete route is exposed.
- Product-specific disciplines are configurable. Stage code/color definitions are shared per workspace; stage creation/update functions lock the workspace before looking up or adding a definition, reject conflicting colors, and preserve each discipline's independent stage order. No stage dates are stored. List queries aggregate `MIN(planned_start)` and `MAX(planned_end)`; the one-query hierarchy read derives the same boundaries from its child activity rows. Empty stages return null boundaries.
- Planned dates are civil PostgreSQL `date` values returned as `YYYY-MM-DD` text. Creation validates Gregorian dates and start/end order. Metadata updates require a current version and reject planned-date fields. A database trigger also rejects any update to existing planned dates; the trigger must be replaced only by a future audited operation that writes the date change and immutable audit record atomically. No importer, targets, dependencies, or revision engine is introduced here.

### Phase 1B.2 schedule editor boundary

- The React editor reads the authorized hierarchy and, for admin/editor roles, the workspace stage-definition catalog. `GET /api/workspaces/:workspaceId/stage-definitions` verifies the JWT and active membership server-side; it never accepts a role or identity supplied by the client. Mutations continue through the Phase 1B.1 endpoints, which recheck workspace, parent ownership, membership, role, validation, and version tokens. UI control visibility is only a usability affordance.
- Dates are displayed and entered as `DD/MM/YYYY` without browser locale or timezone conversion. New activity dates are validated and converted to `YYYY-MM-DD` at the client boundary, then validated again by the Worker. Existing dates are displayed without edit inputs. No database migration or business seed is introduced.

### Phase 1C.1 import preview boundary

- The XLSX parser is loaded only when an active admin/editor opens the Products import preview. It runs in the browser, has bounded file/archive/row limits, and sends no raw workbook to the Worker. All worksheet content is treated as untrusted text and rendered through React text nodes. Formula cells are not executed. Predecessor, duration, and Gantt grid columns are ignored. The Phase 1C.1 preview did not persist rows; Phase 1C.2 adds a separately authorized structured write path.

### Phase 1C.2 import write boundary

- `POST /api/workspaces/:workspaceId/imports` requires the existing verified JWT, same-origin request boundary, and an active admin/editor membership. The Worker accepts at most 256 KiB of JSON, rejects unknown fields including dependencies, checks all reference counts/mappings/dates, and uses a parameterized Worker-only Neon connection. Database credentials and workbook bytes never enter the browser bundle or request body.
- The Worker computes a canonical source-content hash and a full request hash. `public.import_initial_schedule` locks the workspace row, checks the caller's active write membership again, and performs all inserts in one PostgreSQL statement. The single statement uses Neon's HTTP driver without an interactive transaction. Unique workspace idempotency and source-hash constraints protect retries and concurrent submissions. A repeated key with the same request returns the same R00 IDs; a changed request or duplicate source is rejected. The additive migration was applied once to the verified JLProject development branch after explicit approval. A rollback-only synthetic verification passed, and all four new tables were empty afterward.
- The R00 snapshot and source references retain the imported civil dates and provenance. The R00 row cannot be updated or deleted. Existing activity-date update protection remains in force. This phase does not implement revision publication, audited date edits, or provider-session revocation. The previously accepted 15-minute JWT revocation window remains a residual risk. The confidential workbook is never used as a committed test fixture or automatically imported.
- Live synthetic development verification sent two concurrent identical imports through the local Worker; they returned `201` and idempotent `200`. The protected hierarchy returned seven disciplines, 21 stages, and 41 activities. A read-only database check found one batch, one R00, five targets, 51 source references, an empty baseline dependency array, and a target with different official/operational dates. The rollback-only SQL check also exercised failure rollback, duplicate-source rejection, R00 immutability, and the existing activity-date trigger. The real workbook was not submitted.

### Phase 1D.1 schedule read boundary

- `GET /api/workspaces/:workspaceId/products/:productId/targets` reuses the Worker JWT verification and active workspace membership check, verifies product ownership, and queries `public.business_targets` with both workspace and product IDs. Admin, editor, and viewer roles may read; unauthenticated and inactive members remain denied. Other methods cannot mutate targets through this route.
- The browser combines this read-only response with the authorized hierarchy in a single visible-row model for the table and Gantt. Timeline geometry uses ISO civil dates and UTC calendar arithmetic; it does not update schedule rows, calculate successors, or modify immutable R00 data. Existing metadata mutation endpoints keep their role and version checks. Authentication and the accepted bounded JWT replay risk remain as documented above.

### Phase 1D.2A audited date-edit boundary

- `PATCH .../activities/:activityId/dates` and `GET .../activities/:activityId/date-history` use the existing Worker JWT, live active-membership, role, and full ancestry checks. Only admin/editor may change dates; any active member may read history. The Worker derives the actor from the verified JWT, validates ISO civil dates, version and reason, generates the operation UUID, and uses parameterized SQL. The metadata endpoint continues to reject date fields. Errors are generic pt-BR and responses are not cached.
- Migration `0006_activity_date_audit.sql` adds an append-only, workspace-scoped event table. The single-call PostgreSQL `SECURITY DEFINER` function locks the active writer membership and activity, checks the expected version and product status, and updates dates and inserts the event in the same statement. The date trigger checks its effective `current_user` against a dedicated NOLOGIN executor role, then writes the event before accepting the row change. Setting audit context variables in an ordinary SQL session cannot pass this role check. The function has a fixed trusted search path, no dynamic SQL, and a narrowly granted execution privilege. The no-login executor receives only the table privileges needed for this operation; the application role cannot inherit it. The audit table is owned by that executor; the application role receives only SELECT. R00's separate immutability trigger is unchanged.
- The existing `neondb_owner` connection is a privileged database owner with role-creation capability. Its compromise could alter database objects or invoke the controlled function with a false actor parameter, so the database role boundary protects ordinary SQL operations, not a compromised owner or a bypassed Worker. Before broader production use, separate migration ownership from an application login and grant the application role only the required table/function privileges. Keep the Worker credential server-side and rotate it if exposed. The already accepted 15-minute JWT replay window still applies.
- `db/verification/phase1d2a-development.sql` is a rollback-only synthetic check for direct-update and forged-context rejection, audited update, no-op, stale version, unauthorized actor, audit-failure rollback, append-only history, and R00 immutability. It must run only after explicit approval and successful migration on the verified JLProject development branch. It does not retain synthetic rows or touch the imported schedule.

### Phase 1D.3 target management boundary

The Worker exposes workspace/product-scoped target list, create, update, and soft-delete routes. Active membership is checked per request; viewers may read while active admins/editors may mutate. Target IDs are checked as UUIDs and all SQL is parameterized. Updates use a version token; date changes additionally require a reason and a generated operation UUID. Migration `0008_target_management.sql` uses the existing no-login executor for date writes and the append-only date ledger. The limited Worker role receives function execution and target reads, but no target-date update or audit-table write privilege. Imported source IDs, `import_source_rows`, and immutable R00 remain unchanged; targets are hidden from the live list when soft-deleted.

The migration is prepared and reviewed but still requires explicit approval before applying to JLProject development. No live milestone persistence or migration execution has occurred for this phase.

Development migration `0006` was approved and committed. Its first two attempts failed inside a transaction and rolled back; PostgreSQL 18's automatic `CREATEROLE` administrative membership required the final role check to test `SET`/`USAGE`, and ownership transfer required a temporary `SET ROLE` grant. The corrected migration committed. The first synthetic check then exposed a real privilege gap: the existing `neondb_owner` Worker credential can insert into the audit table despite the table ACL naming only the executor, and cannot execute the date function after ownership transfer. A rollback-only direct INSERT probe reached the foreign-key check, confirming effective INSERT access; `SET ROLE` was denied. No synthetic test data was committed and no date-edit API was used.

Corrective migration `0007_worker_least_privilege.sql` was separately approved and applied to JLProject `development` after its grants passed a rollback-only dry run. A new `jlproject_worker` login has a locally generated password held only in ignored `.dev.vars`. It receives the reads, inserts, metadata updates, and function calls used by the existing Worker. It has no direct activity-date UPDATE, audit INSERT/UPDATE/DELETE, table ownership, or role administration. The executor grants that login audited-function EXECUTE and audit-history SELECT. Effective-permission checks confirmed these boundaries, and the single-transaction synthetic audit test passed and rolled back its rows. The Worker now uses this role locally; the privileged owner connection remains for reviewed migrations only. A compromised owner remains capable of bypassing database safeguards; this is an infrastructure credential risk, not a claim of database-owner-proof auditing. [PostgreSQL role documentation](https://www.postgresql.org/docs/current/role-attributes.html) explains why `CREATEROLE` retains an administrative grant on roles it creates even without inherited or `SET ROLE` access.

The restarted local Worker returned `200` for health and `401` for unauthenticated workspace/product reads. Denied synthetic calls verified that the limited role can still execute existing member, stage, and import functions without writing rows. The development administrator separately reported that a synthetic browser edit required a reason, persisted after reload, updated Gantt/stage dates, and appeared in history. A read-only count confirmed an audit event on that synthetic product linked to the persisted activity, although the exact example input values were not independently matched. Two simultaneous controlled database operations on the same synthetic activity with one expected version returned one `updated` and one `stale`; an audited restore returned its dates to the pretest values. Two additional synthetic history events remain, and the final event matches the current dates and version. No imported schedule row was edited. This verifies the development path; it does not remove the accepted JWT replay window or substitute for production backup/restore and operational hardening.

## Access-control policy

### Phase 1E onboarding boundary

The development-only Worker onboarding route requires a valid Neon JWT and an active JLProject workspace administrator before provisioning. It calls the documented Neon Management API's branch-specific Auth user creation endpoint with a Worker-only project-scoped organization API key. The project and development branch IDs are fixed in server code; frontend input supplies only an email and workspace role. The Worker then uses the provider UUID, checks the current administrator again inside a workspace-serialized SQL function, and inserts one active membership under the existing workspace/user unique constraint. Existing provider users are resolved by a unique exact normalized email lookup in the trusted provider table; ambiguous matches fail closed. The invitee uses Neon's emailed password recovery and verification flow. Worker JWT validation continues to require `emailVerified=true`, and each business request rechecks active membership. No app-generated password or setup token exists.

Provisioning and membership insertion are not a distributed transaction. A provider identity may remain without workspace access if the SQL step fails; this is fail-closed and can be retried. The project-scoped API key can affect multiple branches of the JLProject project even though this code targets only development, so it must remain a Worker secret and must not be deployed as-is to production. For this phase, the key was explicitly approved and configured only in ignored `.dev.vars`. This phase does not change the accepted 15-minute JWT revocation delay. [Neon Auth user creation API](https://neon.com/docs/reference/api/auth/create-branch-neon-auth-new-user), [Neon API key scopes](https://neon.com/docs/manage/api-keys), [Neon password recovery](https://neon.com/docs/auth/guides/password-reset).

- **Admin:** members/workspace/catalogs/imports/publication/schedule edits.
- **Editor:** scheduling, import/export, scenario creation; official publication only with explicit permission (MVP default: no).
- **Viewer:** read permitted schedules/events and export permitted data; cannot edit.
- Every resource fetch or mutation requires a valid session, active membership, adequate role, and workspace/product ownership verification.
- **Never trust** browser-submitted `workspace_id`, `user_id`, role, or activity IDs without server validation.
- Use database RLS where feasible as defense in depth; it does not replace API authorization. A service connection is not a substitute for checking the user's role.
- The UI may hide prohibited controls, but the API must also reject unauthorized direct calls.

## Minimum security controls before real business data

1. HTTPS and secure session cookies (`HttpOnly`, `Secure`, appropriate `SameSite`) with CSRF defense for cookie-authenticated mutations.
2. Restrictive CORS, controlled origins, relevant security headers/CSP, and audited dependencies.
3. Worker environment secrets only; no secrets in frontend bundles, git, or logs. Enforce MFA on infrastructure admin accounts.
4. Login and upload rate/resource limits; file content validation; query parameterization and safe text rendering.
5. Append-only audit ledger protected against editing/deleting by ordinary users, both in API and persistence layer.
6. Least-privilege DB access, separate dev/prod environments, controlled migrations.
7. Independent export/backup and a tested restore procedure. **Schedule revisions are not backups.**
8. Optimistic concurrency tokens and atomic transactions for import, edits and publication.
9. Minimal diagnostic logs that never reveal raw workbooks, passwords, cookies, connection strings, or complete sensitive business data.
10. Test unauthenticated access, cross-workspace IDOR, privilege escalation, XSS, spreadsheet formula injection, and data leakage.

## Practical free-tier limitations

- Workers Free has per-request resource limits; processing large `.xlsx` files may exceed CPU limits. Begin with conservative upload limits and a client-side preview supplemented by **authoritative server-side validation**. If necessary, use a different processing service or higher plan, approved before handling real data.
- Database round trips can add latency; use paginated and aggregated portfolio queries.
- Do not depend on provider revision or rollback features as the only recovery strategy; independently export/backup and test restoration.
- If quotas conflict with security or expected usage, present costs rather than weaken protections.

## Go-live gate

Do not ingest confidential production schedules until authentication is validated, API routes and roles are tested, secrets are isolated, imports are atomic, audit controls cannot be bypassed, backup/restore has been demonstrated, and administrator accounts use MFA.

## Official sources to revalidate at implementation time

- Cloudflare React + Vite: https://developers.cloudflare.com/workers/framework-guides/web-apps/react/
- Cloudflare Worker limits: https://developers.cloudflare.com/workers/platform/limits/
- Cloudflare Static Assets billing: https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/
- Cloudflare–Neon: https://developers.cloudflare.com/workers/databases/third-party-integrations/neon/
- Cloudflare secrets: https://developers.cloudflare.com/workers/configuration/secrets/
- Neon authentication flow: https://neon.com/docs/auth/authentication-flow
- Neon managed auth: https://neon.com/blog/neon-backend-is-ga
- GitHub Pages limits: https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits
