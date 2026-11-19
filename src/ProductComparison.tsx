import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type FormEvent } from "react";
import { compareProductSchedules, type ComparisonKind, type ComparisonOverride, type ComparisonRow,
  type ScheduleComparisonResult } from "../domain/product-comparison";
import type { ComparisonSchedule, ProductComparison } from "../worker/product-comparison";
import { authenticatedFetch } from "./auth";
import { ChangeHistoryDialog } from "./ChangeHistoryDialog";
import { formatCivilDate } from "./civil-date";
import { messages } from "./locales/pt-BR";

const copy = messages.comparison;
const pairingCopy = copy.pairing;
type Filter = keyof typeof copy.filters;
type Field = keyof typeof copy.fields;
type Side = ComparisonRow["a"];
type ProductOption = Pick<ProductComparison["left"]["product"], "id" | "name" | "status">;
type Freshness = "current" | "stale" | "unverified";
type LoadedComparison = { snapshot: ProductComparison; result: ScheduleComparisonResult; overrides: ComparisonOverride[] };
type PairingCandidate = { id: string; label: string; kind: ComparisonKind };

const commonFields: Record<ComparisonRow["kind"], readonly Field[]> = {
  discipline: ["shortCode"],
  stage: ["code", "effectiveStart", "effectiveEnd", "dateSource"],
  activity: ["plannedStart", "plannedEnd", "planningMode", "workingDayDuration"],
  target: ["targetDate", "operationalDate"]
};
const dateFields = new Set<Field>(["plannedStart", "plannedEnd", "derivedStart", "derivedEnd", "effectiveStart",
  "effectiveEnd", "targetDate", "operationalDate"]);

function fieldValue(side: Side, field: Field) {
  if (!side) return null;
  if (field === "location") return side.location?.label ?? copy.root;
  if (field === "effectiveStart") return side.effectiveInterval?.start ?? null;
  if (field === "effectiveEnd") return side.effectiveInterval?.end ?? null;
  return side.values[field] ?? null;
}

function formatField(field: Field, value: string | number | null): string {
  if (dateFields.has(field)) return formatCivilDate(typeof value === "string" ? value : null);
  if (value === null || value === "") return copy.unspecified;
  if (field === "dateSource") return value === "planned" ? copy.planned : copy.derived;
  if (field === "planningMode") return value === "working_days" ? copy.workingDays : copy.manual;
  return typeof value === "number" ? value.toLocaleString("pt-BR") : value;
}

function includesRow(row: ComparisonRow, filter: Filter) {
  if (filter === "all") return true;
  if (filter === "ambiguous") return row.status === "ambiguous";
  return row.status === "different" || row.status === "only_a" || row.status === "only_b";
}

function visibleRows(rows: readonly ComparisonRow[], filter: Filter, depth = 0): { row: ComparisonRow; depth: number; context: boolean }[] {
  return rows.flatMap((row) => {
    const children = visibleRows(row.children, filter, depth + 1);
    const matches = includesRow(row, filter);
    return matches || children.length ? [{ row, depth, context: !matches }, ...children] : [];
  });
}

function ComparisonValues({ row, side }: { row: ComparisonRow; side: Side }) {
  if (!side) return <span className="comparison-muted">{row.status === "ambiguous" ? copy.unresolved : copy.absent}</span>;
  const fields = new Set<Field>(commonFields[row.kind]);
  if (row.kind === "activity" && row.a?.values.workingDayDuration == null && row.b?.values.workingDayDuration == null)
    fields.delete("workingDayDuration");
  for (const { field } of row.differences) {
    if (field !== "name" && field !== "displayName" && Object.hasOwn(copy.fields, field)) fields.add(field as Field);
  }
  const labelChanged = !!row.a && !!row.b && row.a.label !== row.b.label;
  return <>
    <strong className={labelChanged ? "comparison-changed" : undefined}>
      {labelChanged && <span className="visually-hidden">{copy.changed}</span>}{side.label}
    </strong>
    {fields.size > 0 && <dl className="comparison-values">
      {[...fields].map((field) => {
        const changed = row.differences.some((difference) => difference.field === field) ||
          ((field === "effectiveStart" || field === "effectiveEnd") && !!row.a && !!row.b &&
            fieldValue(row.a, field) !== fieldValue(row.b, field));
        return <div key={field} className={changed ? "comparison-changed" : undefined}>
          <dt>{copy.fields[field]}</dt>
          <dd>{changed && <span className="visually-hidden">{copy.changed}</span>}{formatField(field, fieldValue(side, field))}</dd>
        </div>;
      })}
    </dl>}
  </>;
}

function ComparisonTable({ title, rows, filter, empty, canChangePairs, availableKinds, onPair, onUnlink }: {
  title: string; rows: ComparisonRow[]; filter: Filter; empty: string; canChangePairs: boolean;
  availableKinds: ReadonlySet<ComparisonKind>; onPair: (row: ComparisonRow) => void; onUnlink: (row: ComparisonRow) => void;
}) {
  const visible = visibleRows(rows, filter);
  return <section className="comparison-section" aria-label={title}>
    <h3>{title}</h3>
    {visible.length === 0 ? <p className="comparison-muted">{rows.length ? copy.noFilterResults : empty}</p> :
      <div className="comparison-scroll" role="region" aria-label={title} tabIndex={0}>
        <table className="comparison-table" aria-label={title}>
          <thead><tr><th scope="col">{copy.item}</th><th scope="col">{copy.a}</th><th scope="col">{copy.b}</th></tr></thead>
          <tbody>{visible.map(({ row, depth, context }) => {
            const item = row.a ?? row.b;
            const kind = row.kind === "activity" && !item?.location ? copy.root : copy.kinds[row.kind];
            return <tr key={`${row.kind}:${row.a ? "a" : "b"}:${item?.id}`} data-kind={row.kind}>
              <th scope="row" style={{ "--comparison-depth": depth } as CSSProperties}>
                <span className="comparison-muted">{kind}</span>{" "}
                <span className="comparison-row-label">{item?.label}</span>{" "}
                <span className="comparison-status" data-status={row.status}>{copy.statuses[row.status]}</span>{" "}
                {context && <><small>{copy.context}</small>{" "}</>}
                {row.match === "suggested" && <small>{copy.suggested}</small>}
                {row.match === "manual" && <small className="comparison-manual">{pairingCopy.manual}</small>}
                {row.status === "ambiguous" && <small>{copy.candidates(row.candidateIds.length)}</small>}
                {item?.location && <span className="visually-hidden"> {copy.fields.location}: {item.location.label}</span>}
                {row.a && row.b && <button className="comparison-row-action back-button" type="button" disabled={!canChangePairs}
                  aria-label={pairingCopy.unlinkFor(row.a.label)} onClick={() => onUnlink(row)}>{pairingCopy.unlink}</button>}
                {row.a && !row.b && availableKinds.has(row.kind) && <button className="comparison-row-action back-button"
                  type="button" disabled={!canChangePairs} aria-haspopup="dialog" aria-label={pairingCopy.openFor(row.a.label)}
                  onClick={() => onPair(row)}>{pairingCopy.open}</button>}
              </th>
              <td><ComparisonValues row={row} side={row.a} /></td>
              <td><ComparisonValues row={row} side={row.b} /></td>
            </tr>;
          })}</tbody>
        </table>
      </div>}
  </section>;
}

function pairingCandidates(result: ScheduleComparisonResult, schedule: ComparisonSchedule): PairingCandidate[] {
  const available = new Set<string>();
  function visit(rows: readonly ComparisonRow[]) {
    for (const row of rows) {
      if (!row.a && row.b) available.add(`${row.kind}:${row.b.id}`);
      visit(row.children);
    }
  }
  visit(result.hierarchy);
  visit(result.targets);

  const candidates: PairingCandidate[] = [];
  const positioned = (label: string, index: number) => `${label} (${pairingCopy.position(index + 1)})`;
  function add(kind: ComparisonKind, id: string, label: string) {
    if (available.has(`${kind}:${id}`)) candidates.push({ kind, id, label });
  }
  schedule.hierarchy.disciplines.forEach((discipline, index) => {
    const disciplineLabel = positioned(`${discipline.shortCode} · ${discipline.name}`, index);
    add("discipline", discipline.id, disciplineLabel);
    discipline.stages.forEach((stage, stageIndex) => {
      const stageLabel = `${disciplineLabel} › ${positioned(`${stage.code} · ${stage.displayName}`, stageIndex)}`;
      add("stage", stage.id, stageLabel);
      stage.activities.forEach((activity, activityIndex) =>
        add("activity", activity.id, `${stageLabel} › ${positioned(activity.name, activityIndex)}`));
    });
  });
  schedule.hierarchy.rootActivities.forEach((activity, index) =>
    add("activity", activity.id, `${copy.root} › ${positioned(activity.name, index)}`));
  schedule.targets.forEach((target, index) => add("target", target.id, positioned(target.name, index)));
  return candidates;
}

function PairingDialog({ row, candidates, disabled, onConfirm, onClose }: {
  row: ComparisonRow; candidates: PairingCandidate[]; disabled: boolean;
  onConfirm: (bId: string) => boolean; onClose: () => void;
}) {
  const [selected, setSelected] = useState("");
  const [rejected, setRejected] = useState(false);
  const suggestions = new Set(row.candidateIds);
  const suggested = candidates.filter(({ id }) => suggestions.has(id));
  const others = candidates.filter(({ id }) => !suggestions.has(id));
  const options = (items: PairingCandidate[]) => items.map(({ id, label }) => <option key={id} value={id}>{label}</option>);
  return <ChangeHistoryDialog title={pairingCopy.title} closeLabel={pairingCopy.close} onClose={onClose}
    className="comparison-pairing-dialog" footer={<>
      <button type="button" className="back-button" onClick={onClose}>{messages.cancel}</button>
      <button type="submit" form="comparison-pairing-form" disabled={disabled || !selected}>{pairingCopy.confirm}</button>
    </>}>
    <p>{copy.a} · <strong>{row.a?.label}</strong></p>
    <form id="comparison-pairing-form" onSubmit={(event) => {
      event.preventDefault();
      if (!disabled && selected && !onConfirm(selected)) setRejected(true);
    }}>
      <label>{pairingCopy.candidate}<select required value={selected} disabled={disabled}
        onChange={(event) => { setSelected(event.target.value); setRejected(false); }}>
        <option value="">{pairingCopy.choose}</option>
        {suggested.length > 0 && <optgroup label={pairingCopy.suggestedCandidates}>{options(suggested)}</optgroup>}
        {others.length > 0 && <optgroup label={pairingCopy.otherCandidates}>{options(others)}</optgroup>}
      </select></label>
      {rejected && <p role="alert">{pairingCopy.invalid}</p>}
    </form>
  </ChangeHistoryDialog>;
}

function sameSnapshot(previous: ProductComparison, latest: ProductComparison): boolean {
  return (["left", "right"] as const).every((side) => previous[side].product.version === latest[side].product.version &&
    previous[side].cursor.scheduleVersion === latest[side].cursor.scheduleVersion &&
    previous[side].cursor.historyWatermark === latest[side].cursor.historyWatermark);
}

export function ProductComparisonPage({ products, catalogState, initialProductId, workspaceId, onRetryCatalog, onAccessLost, onBack }: {
  products: readonly ProductOption[]; catalogState: "loading" | "ready" | "error"; initialProductId: string;
  workspaceId: string; onRetryCatalog: () => void; onAccessLost: () => void; onBack: () => void;
}) {
  const [aId, setAId] = useState(initialProductId);
  const [bId, setBId] = useState("");
  const [loaded, setLoaded] = useState<LoadedComparison | null>(null);
  const [loading, setLoading] = useState(false);
  const [checking, setChecking] = useState(false);
  const [error, setError] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [freshness, setFreshness] = useState<Freshness>("current");
  const [pairingRow, setPairingRow] = useState<ComparisonRow | null>(null);
  const [decisionFeedback, setDecisionFeedback] = useState<{ message: string; invalid?: boolean } | null>(null);
  const request = useRef<AbortController | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const feedbackRef = useRef<HTMLParagraphElement>(null);
  const refreshButton = useRef<HTMLButtonElement>(null);
  const focusRefresh = useRef(false);
  const canCompare = aId !== bId && products.some(({ id }) => id === aId) && products.some(({ id }) => id === bId);
  const snapshot = loaded?.snapshot;
  const result = loaded?.result;
  const candidates = useMemo(() => snapshot && result ? pairingCandidates(result, snapshot.right) : [], [result, snapshot]);
  const availableKinds = new Set(candidates.map(({ kind }) => kind));
  const canChangePairs = !!loaded && !loading && !checking && freshness === "current";
  const overrideCount = loaded?.overrides.length ?? 0;

  useEffect(() => {
    heading.current?.focus();
    return () => request.current?.abort();
  }, []);

  useEffect(() => {
    if (decisionFeedback && !decisionFeedback.invalid) queueMicrotask(() => feedbackRef.current?.focus());
  }, [decisionFeedback]);

  useEffect(() => {
    if (freshness !== "current" && focusRefresh.current) {
      focusRefresh.current = false;
      queueMicrotask(() => refreshButton.current?.focus());
    }
  }, [freshness]);

  const loadComparison = useCallback(async (checkOnly: boolean) => {
    if (checkOnly && (request.current || !snapshot || freshness === "stale")) return;
    if (!canCompare) return;
    request.current?.abort();
    const controller = new AbortController();
    request.current = controller;
    function requireRefresh(status: "stale" | "unverified") {
      focusRefresh.current = !!pairingRow;
      setFreshness(status);
      setPairingRow(null);
    }
    if (checkOnly) setChecking(true);
    else { setChecking(false); setLoading(true); setError(""); setPairingRow(null); setDecisionFeedback(null); }
    try {
      const params = new URLSearchParams({ leftProductId: aId, rightProductId: bId });
      const response = await authenticatedFetch(`/api/workspaces/${workspaceId}/product-comparison?${params}`, { signal: controller.signal });
      if (controller.signal.aborted) return;
      if (response.status === 401 || response.status === 403) {
        setLoaded(null);
        setPairingRow(null);
        setError(copy.error);
        onAccessLost();
        return;
      }
      if (response.status === 404 || response.status === 422) {
        if (checkOnly) { requireRefresh("stale"); return; }
        const body = response.status === 422 ? await response.json().catch(() => null) as { maxEntities?: number } | null : null;
        if (controller.signal.aborted) return;
        setLoaded(null);
        setError(response.status === 404 ? copy.missing : typeof body?.maxEntities === "number"
          ? copy.oversized(body.maxEntities.toLocaleString("pt-BR")) : copy.oversizedUnknown);
        return;
      }
      if (!response.ok) throw new Error("Comparison read failed.");
      const { comparison } = await response.json() as { comparison: ProductComparison };
      if (controller.signal.aborted) return;
      if (comparison?.left?.product.id !== aId || comparison?.right?.product.id !== bId ||
          comparison.left.product.workspaceId !== workspaceId || comparison.right.product.workspaceId !== workspaceId)
        throw new Error("Unexpected comparison scope.");
      if (checkOnly && snapshot) {
        const unchanged = sameSnapshot(snapshot, comparison);
        if (unchanged) setFreshness("current"); else requireRefresh("stale");
      } else {
        setLoaded({ snapshot: comparison, result: compareProductSchedules(comparison), overrides: [] });
        setFreshness("current");
        if (overrideCount > 0) setDecisionFeedback({ message: pairingCopy.reset });
      }
    } catch {
      if (controller.signal.aborted) return;
      if (checkOnly) requireRefresh("unverified");
      else { setLoaded(null); setError(copy.error); }
    } finally {
      if (request.current === controller) {
        request.current = null;
        if (checkOnly) setChecking(false); else setLoading(false);
      }
    }
  }, [aId, bId, canCompare, freshness, onAccessLost, overrideCount, pairingRow, snapshot, workspaceId]);

  useEffect(() => {
    const onFocus = () => { if (snapshot) void loadComparison(true); };
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [loadComparison, snapshot]);

  function changeSelection(side: "a" | "b", id: string) {
    request.current?.abort();
    request.current = null;
    if (side === "a") setAId(id); else setBId(id);
    setLoaded(null);
    setLoading(false);
    setChecking(false);
    setError("");
    setFilter("all");
    setFreshness("current");
    setPairingRow(null);
    setDecisionFeedback(null);
  }

  function applyDecision(row: ComparisonRow, action: ComparisonOverride["action"], bId: string): boolean {
    if (!loaded || !canChangePairs || request.current || !row.a) return false;
    if (action === "pair" && (row.b || !candidates.some((candidate) => candidate.kind === row.kind && candidate.id === bId)))
      return false;
    if (action === "unlink" && (row.b?.id !== bId || !row.match)) return false;
    const decision = { action, kind: row.kind, aId: row.a.id, bId };
    const overrides = loaded.overrides.filter((existing) => existing.kind !== decision.kind ||
      existing.aId !== decision.aId || existing.bId !== decision.bId);
    overrides.push(decision);
    try {
      const result = compareProductSchedules(loaded.snapshot, overrides);
      setLoaded({ ...loaded, result, overrides });
      setPairingRow(null);
      setDecisionFeedback({ message: action === "pair" ? pairingCopy.paired : pairingCopy.unlinked });
      return true;
    } catch {
      return false;
    }
  }

  const tableActions = { canChangePairs, availableKinds, onPair: setPairingRow, onUnlink: (row: ComparisonRow) => {
    if (row.b && !applyDecision(row, "unlink", row.b.id)) setDecisionFeedback({ message: pairingCopy.invalid, invalid: true });
  } };

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!loading && canCompare) void loadComparison(false);
  }

  return <section className="product-comparison" aria-labelledby="product-comparison-title">
    <button type="button" className="back-button" onClick={onBack}>{messages.backToProducts}</button>
    <h2 id="product-comparison-title" tabIndex={-1} ref={heading}>{copy.title}</h2>
    {catalogState === "loading" && <p role="status">{messages.productsLoading}</p>}
    {catalogState === "error" && <div role="alert"><p>{messages.productsError}</p>
      <button type="button" onClick={onRetryCatalog}>{messages.retry}</button></div>}
    {catalogState === "ready" && (products.length < 2 ? <p role="status">{copy.insufficientProducts}</p> :
      <form className="comparison-controls" onSubmit={submit}>
        {(["a", "b"] as const).map((side) => {
          const selected = side === "a" ? aId : bId;
          const other = side === "a" ? bId : aId;
          return <label key={side}>{copy[side]}<select required value={products.some(({ id }) => id === selected) ? selected : ""}
            onChange={(event) => changeSelection(side, event.target.value)}>
            <option value="">{copy.choose}</option>
            {products.filter(({ id }) => id !== other).map((product) =>
              <option key={product.id} value={product.id}>{product.name} · {messages.productStatus[product.status]}</option>)}
          </select></label>;
        })}
        <button type="submit" ref={refreshButton} disabled={!canCompare || loading}>{snapshot ? copy.refresh : error ? messages.retry : copy.submit}</button>
      </form>)}
    {loading && <p role="status">{copy.loading}</p>}
    {error && <p role="alert">{error}</p>}
    {result && <div className="comparison-result" aria-busy={loading}>
      {freshness !== "current" && <p className="comparison-notice" role="status">{copy[freshness]} {pairingCopy.refreshRequired}</p>}
      <div className="comparison-products">
        {(["a", "b"] as const).map((side) => <div key={side}>
          <span className="comparison-muted">{copy[side]}</span>
          <h3>{result[side].name}</h3>
          <span className={`product-card__status${result[side].status === "arquivado" ? " product-card__status--archived" : ""}`}>
            {messages.productStatus[result[side].status]}
          </span>
        </div>)}
      </div>
      <div className="comparison-overview">
        <dl className="comparison-summary" aria-label={copy.summary}>
          {([
            [copy.differences, result.summary.different], [copy.statuses.only_a, result.summary.only_a],
            [copy.statuses.only_b, result.summary.only_b], [copy.suggestions, result.summary.suggested],
            [pairingCopy.manualCount, result.summary.manual],
            [copy.ambiguousItems, result.summary.ambiguous]
          ] as const).map(([label, count]) => <div key={label}><dt>{label}</dt><dd>{count.toLocaleString("pt-BR")}</dd></div>)}
        </dl>
        {(result.hierarchy.length > 0 || result.targets.length > 0) && <label>{copy.filter}<select value={filter}
          onChange={(event) => setFilter(event.target.value as Filter)}>
          {(Object.keys(copy.filters) as Filter[]).map((value) => <option key={value} value={value}>{copy.filters[value]}</option>)}
        </select></label>}
      </div>
      {decisionFeedback && <p ref={feedbackRef} className="comparison-feedback" tabIndex={-1}
        role={decisionFeedback.invalid ? "alert" : "status"}>{decisionFeedback.message}</p>}
      {result.summary.suggested > 0 && <p className="comparison-muted">{copy.suggestionHelp}</p>}
      {result.hierarchy.length === 0 && result.targets.length === 0 ? <p role="status">{copy.empty}</p> : <>
        <ComparisonTable title={copy.hierarchy} rows={result.hierarchy} filter={filter} empty={copy.emptyHierarchy} {...tableActions} />
        <ComparisonTable title={copy.targets} rows={result.targets} filter={filter} empty={copy.emptyTargets} {...tableActions} />
      </>}
    </div>}
    {pairingRow && <PairingDialog row={pairingRow} candidates={candidates.filter(({ kind }) => kind === pairingRow.kind)}
      disabled={!canChangePairs} onConfirm={(bId) => applyDecision(pairingRow, "pair", bId)} onClose={() => setPairingRow(null)} />}
  </section>;
}
