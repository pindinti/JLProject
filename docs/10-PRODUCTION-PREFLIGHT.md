# Production Preflight

This document prepares the first internal deployment only. It does not authorize creating Neon or Cloudflare resources, applying production migrations, uploading secrets, or deploying.

## Target architecture

- Create a **new, empty Neon project dedicated to production**. Do not branch from or copy the development project. Create its `production` branch, enable branch-specific Neon Auth, and verify the Auth URL and database endpoint belong to this project and branch.
- Keep email/password sign-in, required email verification, disabled public registration, and password recovery. Add only the final HTTPS application origin to Neon Auth trusted origins and redirect allowlists. Test recovery email delivery before inviting users.
- Deploy the Cloudflare production environment as Worker `jlproject` with `workers_dev` enabled at `https://jlproject.pauloelp.workers.dev`. `JLPROJECT_ENV=production` is configured in `wrangler.jsonc`. The production frontend Auth URL is a public build-time value in `.env.production.local`, based on `.env.production.example`.
- Set only a limited `jlproject_worker` PostgreSQL connection string as Worker secret `DATABASE_URL`. Set the production Auth URL as the Worker variable/secret `NEON_AUTH_BASE_URL`. Keep the migration-owner connection local and temporary. **Never add `NEON_MANAGEMENT_API_KEY` to Cloudflare.** The Worker onboarding integration is guarded to development; production onboarding uses the local operator procedure below.
- Preserve the accepted 15-minute JWT replay limitation only after an explicit production risk review. D023/P001 requires reassessment before broader deployment. Backup and restore must also be tested before confidential schedules are loaded.

## Fresh production database sequence

1. With explicit approval, create the blank production Neon project and branch; enable Neon Auth and verify public signup is off, email verification is on, recovery email delivery works, and the final HTTPS origin is trusted. Do not clone development data, users, or sessions.
2. Verify the fresh project's migration owner is `neondb_owner`, as required by `0006`–`0008`; stop if that assumption is false. Create the separate `jlproject_worker` login before migration `0007`, using a generated password. With the private migration-owner connection, apply these files one at a time in numeric order, stopping on any failure: `0001_workspace_authorization.sql`, `0002_membership_administration.sql`, `0003_products.sql`, `0004_schedule_hierarchy.sql`, `0005_initial_import.sql`, `0006_activity_date_audit.sql`, `0007_worker_least_privilege.sql`, `0008_target_management.sql`, `0009_user_onboarding.sql`. Review each migration and record its filename, checksum, branch, operator, and result. These migrations create a fresh schema additively; `0007` establishes reviewed application grants. Use only the limited Worker login's connection string in Cloudflare. Never use the owner connection in Worker secrets.
3. Provision the first production Auth identity locally with the authenticated Neon CLI, scoped explicitly to the production project and branch: `npx neon@latest neon-auth user create --project-id <production-project-id> --branch production --email <admin-email>`. The CLI operator session stays on the administrator's machine; do not use a project management key in the Worker. Have the owner follow the emailed recovery and verification flow. Verify the exact Auth UUID and verified-email status in that production branch.
4. Review `db/bootstrap-production-admin.sql.example`, fill a private copy with only the verified UUID and workspace name, execute it once against production, and confirm one workspace plus one active admin. Do not use the development template.
5. Provision the other 1–2 approved users the same way from the operator CLI. After each user verifies email, the production admin can use **Administração → Usuários** to add the existing identity by exact email and assign the least necessary role. Duplicate attempts must be rejected. Do not enable public registration.

## Cloudflare release sequence (requires separate approval)

1. Confirm the production project ID, production branch/Auth URL, Worker name `jlproject`, HTTPS origin `https://jlproject.pauloelp.workers.dev`, Cloudflare account, and rollback owner with the release owner.
2. Set `VITE_NEON_AUTH_URL` from the production Auth URL in the trusted build environment; this URL is public. In PowerShell, set `CLOUDFLARE_ENV=production` and `VITE_NEON_AUTH_URL`, run `npm run build`, then remove both process variables. Inspect the generated `dist/worker/wrangler.json` for `JLPROJECT_ENV=production`, Worker name `jlproject`, enabled `workers_dev`, and `/api/*` Worker routing. The build removes `.dev.vars*` from output.
3. Add `DATABASE_URL` and `NEON_AUTH_BASE_URL` only to the production Worker environment (for example, `npx wrangler secret put DATABASE_URL --env production` and `npx wrangler secret put NEON_AUTH_BASE_URL --env production`). Do not upload development values, the migration-owner connection, or `NEON_MANAGEMENT_API_KEY`. Confirm the secret inventory before release.
4. Verify the workers.dev HTTPS hostname and Neon Auth trusted origin/redirect allowlists.
5. After approval and custom-domain configuration, run `npx wrangler deploy`; the Vite plugin directs Wrangler to the generated production configuration. Smoke test: `/api/health` returns 200 with a generic body; unauthenticated workspace and business endpoints return 401; verified admin login and membership return 200; editor/viewer permissions and cross-workspace isolation return expected statuses; password recovery works; no development identity or data appears. Use synthetic records only and remove or soft-archive them after checks.
6. Verify logs and browser assets contain no database URLs, management keys, JWTs, cookies, or personal information. Confirm backup schedule, restore procedure, monitoring, and rollback steps before loading confidential business schedules.

## Blocking decisions and approvals

- Approve creation of a new production Neon project/branch and branch-specific Auth configuration.
- Confirm the production custom domain and HTTPS origin.
- Review and explicitly accept or mitigate D023's up-to-15-minute JWT replay risk for production.
- Approve the migration run, production Worker credential creation, first-admin identity/workspace bootstrap, and Cloudflare deployment as separate operations.
- Demonstrate a production backup restore and confirm recovery email delivery before confidential data use.

The first 2–3 users can be provisioned with the local authenticated Neon CLI and provider recovery email. No project-wide or project-scoped Neon Management API key is needed in the public Worker.
