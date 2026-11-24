# REL-05 Production hotfix provenance

This supplement records the release owner's approval of the live November 13, 2026 hotfix for the Phase 4B.5 backup preparation. The [original REL-05 release report](../12-REL-05-RELEASE-REPORT.md) remains the record of the earlier deployment.

| Item | Recorded value |
| --- | --- |
| Source commit identified by the release owner | `324c6ec4ddc44c665ca5cf6e306b6b05bdc2f778` |
| Canonical Worker | `jlproject` |
| Deployment | `9daeec47-6ca0-4961-b6fc-4ef19b5eb239` |
| Active version | `14ca5d89-8988-4acc-84db-a37ac98f199f` at 100% |

The local Git diff contains stage creation diagnostics and schedule visibility changes, including expanding the product and hierarchy to reveal newly created stages. It contains no migration or Excel import implementation changes. Cloudflare independently confirmed the canonical deployment and its version, the `production` environment marker, and the presence and type of the `DATABASE_URL` and `NEON_AUTH_BASE_URL` bindings. The current Cloudflare Worker inventory showed no separate `jlproject-production` script.

The release owner supplied the commit-to-deployment association, confirmed that the Production database binding was unchanged, and approved the identified live deployment. Cloudflare binding metadata does not expose the database destination or prove the deployed build's Git provenance. Neon independently confirmed the intended target as project `crimson-glade-72578238`, branch `br-orange-shadow-b6yu9uxu`, and database `neondb`.
