import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0035_product_cloning_compatibility.sql", "utf8");
const verification = readFileSync("db/verification/phase2.1-0035-rollback.sql", "utf8");
const originalRoot = readFileSync("db/migrations/0025_root_activities.sql", "utf8");
const statusChange = readFileSync("db/migrations/0034_product_status_study_workflow.sql", "utf8");

describe("migration 0035 clone compatibility", () => {
  it("changes archived source eligibility without opening an existing target write path", () => {
    expect(originalRoot).toContain("AND id = p_source_product_id AND active = true");
    expect(statusChange).toContain("AND product.active IN (true, false)");
    expect(migration).toContain("replace(v_definition, v_anchor, 'AND id = p_source_product_id')");
    expect(migration).toMatch(/AND created_by = p_actor_id AND xmin::text::bigint = txid_current\(\) % 4294967296/g);
    expect(migration).toContain("p_source_product_id = p_target_product_id");
    expect(migration).toContain("role IN ('admin', 'editor')");
    expect(migration).toContain("activity.deleted_at IS NULL FOR UPDATE OF activity");
  });

  it("copies stage planning metadata through an executor-owned helper and includes it in R00", () => {
    expect(migration).toContain("CREATE FUNCTION public.clone_stage_activity(");
    expect(migration).toContain("LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp");
    expect(migration).toContain("v_activity.planning_mode, v_activity.working_day_duration,");
    expect(migration).toContain("v_activity.planning_calendar_version, p_actor_id, p_actor_id");
    expect(migration).toContain("'planningMode', v_activity.planning_mode");
    expect(migration).toContain("'workingDayDuration', v_activity.working_day_duration");
    expect(migration).toContain("'planningCalendarVersion', v_activity.planning_calendar_version");
    expect(migration).toContain("v_activity_id := public.clone_stage_activity(");
    expect(migration).not.toContain("source_external_id, created_by, updated_by");
  });

  it("preserves atomic migration and least-privilege ordering", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    const grantRole = migration.indexOf("GRANT jlproject_date_executor TO neondb_owner");
    const grantCreate = migration.indexOf("GRANT CREATE ON SCHEMA public TO jlproject_date_executor");
    const setRole = migration.indexOf("SET ROLE jlproject_date_executor");
    const resetRole = migration.indexOf("RESET ROLE;");
    const revokeCreate = migration.indexOf("REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor");
    const revokeRole = migration.indexOf("REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;");
    expect(grantRole).toBeGreaterThan(0);
    expect(grantCreate).toBeGreaterThan(grantRole);
    expect(setRole).toBeGreaterThan(grantCreate);
    expect(resetRole).toBeGreaterThan(setRole);
    expect(revokeCreate).toBeGreaterThan(resetRole);
    expect(revokeRole).toBeGreaterThan(revokeCreate);
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT')");
    expect(migration).not.toMatch(/\b(UPDATE|DELETE|TRUNCATE)\s+public\./i);
    expect(migration).not.toContain("UPDATE public.initial_schedule_revisions");
  });

  it("checks the exact root helper search path as an array entry and rejects missing settings", () => {
    expect(migration).toMatch(/\(SELECT proconfig @> ARRAY\['search_path=pg_catalog, pg_temp'\] FROM pg_proc WHERE oid =\s+'public\.clone_root_activity\(uuid,uuid,uuid,uuid,uuid\)'::regprocedure\) IS NOT TRUE OR/);
    expect(migration).not.toMatch(/=\s*ANY\s*\(\s*\(\s*SELECT\s+proconfig/i);
  });

  it("requires the same cloud_admin membership before the temporary grant and after revocation", () => {
    const grant = "GRANT jlproject_date_executor TO neondb_owner\n" +
      "  WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;";
    const revoke = "REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;";
    const sql = migration.replace(/\r\n/g, "\n");
    const membershipCheck = /NOT \(SELECT count\(\*\) = 1 AND count\(\*\) FILTER \(\s+WHERE grantor = to_regrole\('cloud_admin'\) AND admin_option\s+AND NOT inherit_option AND NOT set_option\) = 1\s+FROM pg_catalog\.pg_auth_members\s+WHERE roleid = 'jlproject_date_executor'::regrole\s+AND member = 'neondb_owner'::regrole\) OR/;
    expect(sql.indexOf(grant)).toBeGreaterThan(0);
    expect(sql.indexOf(revoke)).toBeGreaterThan(sql.indexOf(grant));
    expect(sql.slice(0, sql.indexOf(grant))).toMatch(membershipCheck);
    expect(sql.slice(sql.indexOf(revoke) + revoke.length)).toMatch(membershipCheck);
    expect(sql).not.toContain("pg_has_role('neondb_owner', 'jlproject_date_executor', 'member')");
  });

  it("prepares rollback-only working schedule and baseline checks", () => {
    expect(verification).toMatch(/^\\set ON_ERROR_STOP on\s+BEGIN;/);
    expect(verification).toMatch(/ROLLBACK;\s*$/);
    expect(verification).toContain("'Stage working activity'");
    expect(verification).toContain("'Root working activity'");
    expect(verification).toContain("planned_end IS NULL");
    expect(verification).toContain("revision.label = 'R00'");
    expect(verification).toContain("v_source_fingerprint");
  });
});
