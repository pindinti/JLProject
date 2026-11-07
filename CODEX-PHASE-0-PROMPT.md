# Codex prompt — Phase 0 architecture and implementation plan

**Recommended model:** GPT-5.6 Sol (if available in Codex).  
**Recommended reasoning effort:** Medium.  
**Reason:** This is a bounded architectural review that benefits from reasoning without the cost of a maximal-effort agentic run. If unavailable, use the closest balanced coding model in your Codex model selector.

Copy the following English prompt into Codex after placing this documentation package at the root of the private JLProject repository.

---

We are starting JLProject, an internal, web-based, multi-user product schedule management tool inspired by Microsoft Project. The MVP will include detailed and portfolio Gantt charts, existing Excel schedule imports, configurable target-date markers, mandatory audit trails for date edits, user-defined cross-discipline dependencies with minimum-change rescheduling, and independent schedule revisions/scenarios.

**Read `AGENTS.md`, `README.md`, and all files in `docs/` before proposing code.** Treat recorded product decisions as authoritative, and flag conflicts rather than assuming. All project documentation, prompts, code comments, and technical responses must be in English. **All application UI copy and user-facing messages must be Brazilian Portuguese (`pt-BR`).** See `docs/09-LOCALIZATION.md`.

Important import constraint: the reference Excel file contains unreliable predecessor values. **Never import, infer, or attempt to repair those dependencies.** The initial target is to import 41 operational activities, their original dates, and five goals, with zero dependencies. Dependencies will be configured later by users inside JLProject.

Work on **Phase 0 only**, as defined in `docs/07-DELIVERY-PLAN.md`.

Before changing files:

1. Summarize the product and its architecture-relevant requirements in no more than 15 points.
2. Identify documentation inconsistencies, open technical decisions, and risks, especially enterprise access security, authentication, Cloudflare Workers Free quotas, and secure `.xlsx` processing.
3. Recommend an appropriate folder structure, final initial stack, and database migration, testing, and deployment strategies. Explain meaningful tradeoffs using current official provider documentation.
4. Propose a small, testable Phase 0 implementation plan with acceptance criteria and exact files you expect to create or modify.
5. **Stop and request approval before creating or changing application code.** Do not implement the Gantt, Excel import, dependency engine, scenarios, or later phases.

Candidate stack: React + TypeScript + Vite; API and static assets on Cloudflare Workers; Neon PostgreSQL; managed authentication if it meets our security and access requirements. Never put `DATABASE_URL` into the browser bundle, never treat a mock login as real production security, and never commit confidential spreadsheets.

Keep the response concise, in English. Distinguish approved requirements from unverified technical assumptions.

---

## Follow-up prompt after Phase 0 approval (template; adapt in this chat)

Phase 0 plan approved with these adjustments: [adjustments]. Implement **only Phase 0**. Add the planned tests, run lint/typecheck/test/build, and summarize changed files and remaining risks. Keep all technical communication and documentation in English and all visible application UI copy in `pt-BR`. If you encounter a security or infrastructure blocker, stop and explain the safest option rather than silently weakening controls.
