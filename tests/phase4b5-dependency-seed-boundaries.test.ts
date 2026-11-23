import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { assessDependencyBoundaryChange } from "../domain/schedule-dependencies";
import { isNonWorkingDate } from "../domain/working-calendar";

const read = (file: string) => readFileSync("db/verification/" + file + ".sql", "utf8").replace(/\r\n/g, "\n");
const hierarchy = "phase4b3c2-hierarchy-move";
const deletion = "phase4b3c3-schedule-deletion";

function nextWorkday(date: string) {
  const day = new Date(date + "T00:00:00Z");
  let iso: string;
  do {
    day.setUTCDate(day.getUTCDate() + 1);
    iso = day.toISOString().slice(0, 10);
  } while (isNonWorkingDate(iso, []));
  return iso;
}

function readSeed(base: string) {
  const structure = read(base + "-seed-owner");
  const activities = [...structure.matchAll(
    /\(:'(\w+)', :'test_workspace', :'(\w+)', (.*?), (?::'(\w+)'|NULL), '[^']+', DATE '([\d-]+)', DATE '([\d-]+)', \d+, :'test_actor', :'test_actor'\)/g,
  )].map(([, id, product, discipline, stage, start, end]) => ({ id, product, discipline, stage, start, end }));
  const stages = [...structure.matchAll(
    /\(:'(\w+)', :'test_workspace', :'(\w+)', (.*?), :'[^']+', '[^']+', \d+, :'test_actor', :'test_actor', NULL, NULL\)/g,
  )].map(([, id, product, discipline]) => ({ id, product, discipline }));
  const explicit = new Map([...read(base + "-seed-worker-stage-dates").matchAll(
    /^\\set test_stage :(\w+)\n[\s\S]*?^\\set test_start ([\d-]+|__NULL__)\n\\set test_end ([\d-]+)/gm,
  )].map(([, id, start, end]) => [id, { start: start === "__NULL__" ? null : start, end }]));
  function effective(product: string, kind: string, id: string) {
    if (kind === "activity") return activities.find((row) => row.product === product && row.id === id);
    const stage = stages.find((row) => row.product === product && row.id === id);
    if (!stage) return undefined;
    const children = activities.filter((row) =>
      row.product === product && row.discipline === stage.discipline && row.stage === id);
    return explicit.get(id) ?? {
      start: children.map((row) => row.start).sort().at(0) ?? null,
      end: children.map((row) => row.end).sort().at(-1) ?? null,
    };
  }
  const assignments = new Map<string, string>();
  const edges = [];
  for (const line of read(base + "-seed-owner-dependencies").split("\n")) {
    const assignment = /^\\set (test_(?:product|edge_id|endpoint_kind|predecessor_id|successor_id)) :?([-\w]+)$/.exec(line);
    if (assignment) assignments.set(assignment[1], assignment[2]);
    if (line !== "\\i db/verification/phase4b5-seed-one-dependency.sql") continue;
    const get = (key: string) => {
      const value = assignments.get("test_" + key);
      if (!value) throw new Error("Missing edge seed assignment: " + key);
      return value;
    };
    const product = get("product");
    const kind = get("endpoint_kind");
    const predecessor = effective(product, kind, get("predecessor_id"));
    const successor = effective(product, kind, get("successor_id"));
    const predecessorFinish = predecessor?.end;
    const successorStart = successor?.start;
    if (!predecessorFinish || !successorStart) throw new Error("Missing scoped boundary for " + get("edge_id"));
    edges.push({ predecessorFinish, successorStart, earliestStart: nextWorkday(predecessorFinish) });
  }
  return { edges, activities };
}

describe("dependency seed boundaries", () => {
  it.each([[hierarchy, 6], [deletion, 5]])("seeds all %s edges with scoped Finish-to-Start dates", (base, count) => {
    const { edges } = readSeed(base);
    expect(edges).toHaveLength(count);
    for (const edge of edges) expect(edge.successorStart >= edge.earliestStart).toBe(true);
  });

  it("introduces the conflict only on reparenting and keeps the valid round trip", () => {
    const { edges, activities } = readSeed(hierarchy);
    const newFinish = activities.find((row) => row.id === "test_conflict_activity")?.end;
    if (!newFinish) throw new Error("Missing conflict activity");
    expect(edges[0]).toEqual({
      predecessorFinish: "2026-11-05", successorStart: "2026-11-06", earliestStart: "2026-11-06",
    });
    expect(assessDependencyBoundaryChange(edges[0], {
      ...edges[0], predecessorFinish: newFinish, earliestStart: nextWorkday(newFinish),
    })).toBe("finish_to_start");
    const validMove = activities.find((row) => row.id === "test_valid_activity")?.end;
    if (!validMove) throw new Error("Missing valid activity");
    const validBefore = edges[2];
    const validFinish = validMove > validBefore.predecessorFinish ? validMove : validBefore.predecessorFinish;
    const validAfter = { ...validBefore, predecessorFinish: validFinish, earliestStart: nextWorkday(validFinish) };
    expect(validBefore.predecessorFinish).toBe("2026-11-05");
    expect(assessDependencyBoundaryChange(validBefore, validAfter)).toBeNull();
    expect(assessDependencyBoundaryChange(validAfter, validBefore)).toBeNull();
  });

  it("tests loss of the sole root scenario finish before the valid root-to-stage move", () => {
    const { edges, activities } = readSeed(hierarchy);
    expect(activities.filter((activity) => activity.stage === "test_root_stage")).toHaveLength(1);
    expect(assessDependencyBoundaryChange(edges[5], {
      ...edges[5], predecessorFinish: null, earliestStart: null,
    })).toBe("missing_boundary");
    const runtime = read(hierarchy);
    expect(runtime).toMatch(/SELECT id INTO STRICT v_root_boundary_child[\s\S]*?v_root_boundary_child, \(SELECT version[\s\S]*?'missing_boundary'[\s\S]*?Synthetic root to stage move/);
  });

  it("checks the six positive edges as executor before starting their writes", () => {
    const source = read(hierarchy + "-seed-owner-dependencies");
    expect(source).toMatch(/SET LOCAL ROLE jlproject_date_executor;[\s\S]*?dependency_first_working_start[\s\S]*?v_edge\.finish IS NULL[\s\S]*?v_edge\.start < v_edge\.earliest_start[\s\S]*?REVOKE jlproject_date_executor/);
    expect(source.indexOf("requires valid Finish-to-Start boundaries"))
      .toBeLessThan(source.indexOf("\\i db/verification/phase4b5-seed-one-dependency.sql"));
  });
});
