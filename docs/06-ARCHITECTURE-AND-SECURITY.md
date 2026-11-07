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

## Authentication proof-of-concept checklist

- Check identity-provider session integration with same-origin SPA/API.
- Validate invitation/creation policy: **public sign-up must not automatically grant access to any corporate workspace**. If restricting sign-up is unavailable, deny every session without an approved membership and minimize public registration exposure.
- Verify email verification, password recovery, secure logout, revocation, and session expiry.
- Implement actual server-side roles and workspace scope; do not rely only on frontend conditional rendering.
- Audit authorship must link to the correct authenticated subject ID.
- Inspect free-tier limits, inactivity suspension, service availability, and exit strategy. If the selected provider fails enterprise requirements, propose an alternative before coding production authentication.

## Access-control policy

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
