# REL-05 Production Release Report

Release completed on 2026-11-13. Production received the approved application release after the incremental database migration and verification phases.

## Release identifiers

- Source commit: `c7303dd464efde744e6abc3847844c5f0972e9bf`.
- Production Neon project/branch: `crimson-glade-72578238` / `br-orange-shadow-b6yu9uxu`.
- Migration chain: `0011` through `0027`, applied once in order and individually verified.
- Pre-upgrade backup: `backup-pre-release-20261113`, branch `br-round-band-b6qslh9d`; retained after release.
- Cloudflare Worker: `jlproject`, deployment `a407dbfc-9cae-4111-9de2-16355979852a`, version `6d5dc648-0764-46bc-bf6c-8dcfee6d9ea1`.
- Production URL: `https://jlproject.pauloelp.workers.dev/`.

## Verification

The production database Run completed 17/17 migrations. The final Verify report reached `verified`; schema, privileges, integrity and audit ledgers passed. The saved final snapshot matched the post-freeze baseline: 1 workspace, 4 memberships, 6 products, 21 disciplines, 47 stages, 99 activities, 19 targets, 1 import batch, 51 source rows and 1 R00. The activity-date fingerprint remained `548d37609a8773701c88907741716336`; the independent R00 fingerprint remained `1f4e4ebde42f6a10db014f2dda707e6b`.

The Worker was deployed from the reviewed production build while public ingress was disabled. Version `6d5dc648-0764-46bc-bf6c-8dcfee6d9ea1` became active at 100%. The previously enabled workers.dev and Version URL settings were restored after deployment. The public root, `/api/health`, and release JavaScript asset returned HTTP 200. The release owner subsequently confirmed the production smoke round passed 4/4; the individual account-specific observations are not reproduced here.

Production Auth configuration used the public URL enforced by `scripts/production-auth-url.ts`. The Worker continues to use the existing `DATABASE_URL` and `NEON_AUTH_BASE_URL` secrets; this release did not change their values, Auth identities, memberships, or database data.

## Recovery boundary and limitations

The retained pre-upgrade backup is the database recovery point; no automatic database rollback was performed. Application rollback is a separate Worker-version operation and does not reverse database migrations. Keep the backup until the release owner closes the recovery window. Do not restore the older Worker without reviewing compatibility with migrations `0026` and `0027`.

The known Excel import E2E investigation was inconclusive and is not recorded as a confirmed defect. Viewer-role testing remains deferred. Formal visual revision management after R00, Gantt timeline drag-to-reschedule, and Excel export are not implemented. See [the consolidated backlog](13-BACKLOG.md).

Detailed, sanitized operator evidence remains outside the repository under the release evidence directory. Do not commit database snapshots, transcripts, freeze attestations, or account-specific smoke data.
