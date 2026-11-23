import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const sql = readFileSync("db/migrations/0037_controlled_schedule_dependencies.sql", "utf8");
const verification = readFileSync("db/verification/phase4b2-confirmation-rollback.sql", "utf8");

describe("migration 0037 source contract", () => {
  it("keeps the routines private and preserves the existing activity audit key", () => {
    expect(sql).toMatch(/^BEGIN;\s/);
    expect(sql).toMatch(/COMMIT;\s*$/);
    expect(sql).toContain("FROM PUBLIC, jlproject_worker;");
    expect(sql).not.toMatch(/GRANT\s+EXECUTE|ALTER\s+TABLE\s+public\.activity_date_changes/i);
    expect(sql).toContain("v_source_operation := gen_random_uuid();");
    expect(sql).toContain("SELECT audit.event_id INTO STRICT v_event FROM public.stage_date_changes");
  });

  it("takes locks and validates freshness and the graph before writing, then requires exact audit links", () => {
    const confirmation = sql.slice(sql.indexOf("CREATE FUNCTION public.confirm_schedule_dependencies"));
    const workspaceLock = confirmation.indexOf("FROM public.workspaces WHERE id = p_workspace FOR SHARE");
    const productLock = confirmation.indexOf("WHERE workspace_id = p_workspace AND id = p_product FOR UPDATE");
    const fingerprintCheck = confirmation.indexOf("IS DISTINCT FROM p_fingerprint");
    const cycleCheck = confirmation.indexOf("WITH RECURSIVE downstream");
    const firstWrite = confirmation.indexOf("INSERT INTO public.product_schedule_dependencies");
    expect(workspaceLock).toBeGreaterThan(0);
    expect(productLock).toBeGreaterThan(workspaceLock);
    expect(fingerprintCheck).toBeGreaterThan(productLock);
    expect(cycleCheck).toBeGreaterThan(fingerprintCheck);
    expect(firstWrite).toBeGreaterThan(cycleCheck);
    expect(confirmation).toContain("source_operation_id = v_source_operation AND source_event_id = v_event");
    expect(confirmation).toContain("v_new_version <> p_version + 1");
    expect(verification).toContain("EXCEPTION WHEN SQLSTATE 'ZX042' THEN NULL;");
    expect(verification).toContain("A failed dependency confirmation left persistent changes.");
    expect(verification).toMatch(/ROLLBACK;\s*$/);
  });
});
