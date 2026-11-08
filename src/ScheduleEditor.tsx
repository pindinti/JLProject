import { type FormEvent, useCallback, useEffect, useRef, useState } from "react";
import { authenticatedFetch, type WorkspaceSummary } from "./auth";
import { messages } from "./locales/pt-BR";
import { formatCivilDate, parseBrazilianDate } from "./civil-date";
import { ScheduleWorkspace } from "./ScheduleWorkspace";
import type { ScheduleTarget, VisibleRow } from "../domain/schedule-workspace";

export interface ScheduleProduct { id: string; name: string; active: boolean }
interface Activity {
  id: string; stageId: string; name: string; activityType: string | null;
  plannedStart: string | null; plannedEnd: string | null;
  displayOrder: number; notes: string | null; version: number;
}
interface Stage {
  id: string; disciplineId: string; code: string; color: string; displayName: string;
  displayOrder: number; derivedStart: string | null; derivedEnd: string | null;
  version: number; activities: Activity[];
}
interface Discipline {
  id: string; productId: string; name: string; shortCode: string; color: string;
  displayOrder: number; description: string | null; version: number; stages: Stage[];
}
interface Hierarchy { productId: string; disciplines: Discipline[] }
interface StageDefinition { id: string; code: string; color: string }
type DraftKind = "discipline" | "stage" | "activity";
interface Draft {
  kind: DraftKind; id?: string; disciplineId?: string; stageId?: string; version?: number;
  name: string; shortCode: string; code: string; color: string; displayName: string;
  displayOrder: string; description: string; activityType: string;
  plannedStart: string; plannedEnd: string; notes: string; definitionId: string;
}
const newDefinition = "new";

function initialDraft(kind: DraftKind): Draft {
  return { kind, name: "", shortCode: "", code: "", color: "#336699", displayName: "",
    displayOrder: "0", description: "", activityType: "", plannedStart: "", plannedEnd: "",
    notes: "", definitionId: newDefinition };
}

export function ScheduleEditor({ workspace, product, onBack, onAccessLost }: {
  workspace: WorkspaceSummary; product: ScheduleProduct;
  onBack: () => void; onAccessLost: () => void;
}) {
  const [hierarchy, setHierarchy] = useState<Hierarchy | null>(null);
  const [definitions, setDefinitions] = useState<StageDefinition[]>([]);
  const [targets, setTargets] = useState<ScheduleTarget[]>([]);
  const [state, setState] = useState<"loading" | "ready" | "error" | "notFound">("loading");
  const [openDisciplines, setOpenDisciplines] = useState<Set<string> | null>(null);
  const [openStages, setOpenStages] = useState<Set<string> | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");
  const drawerRef = useRef<HTMLDivElement>(null);
  const previousFocus = useRef<HTMLElement | null>(null);
  const canEdit = product.active && (workspace.role === "admin" || workspace.role === "editor");
  const base = `/api/workspaces/${workspace.id}/products/${product.id}`;

  const load = useCallback(async (showLoading = true) => {
    if (showLoading) setState("loading");
    try {
      const [treeResponse, targetsResponse, definitionsResponse] = await Promise.all([
        authenticatedFetch(`${base}/hierarchy`),
        authenticatedFetch(`${base}/targets`),
        canEdit ? authenticatedFetch(`/api/workspaces/${workspace.id}/stage-definitions`) : Promise.resolve(null)
      ]);
      if ([treeResponse, targetsResponse, definitionsResponse].some((result) => result?.status === 401 || result?.status === 403)) {
        onAccessLost(); return;
      }
      if (treeResponse.status === 404) { setState("notFound"); return; }
      if (!treeResponse.ok || !targetsResponse.ok || (definitionsResponse && !definitionsResponse.ok))
        throw new Error("Schedule lookup failed.");
      const tree = (await treeResponse.json() as { hierarchy: Hierarchy }).hierarchy;
      const targetList = (await targetsResponse.json() as { targets: ScheduleTarget[] }).targets;
      const catalog = definitionsResponse
        ? (await definitionsResponse.json() as { stageDefinitions: StageDefinition[] }).stageDefinitions : [];
      setHierarchy(tree);
      setTargets(targetList);
      setDefinitions(catalog);
      setOpenDisciplines((previous) => previous ?? new Set(tree.disciplines.map((item) => item.id)));
      setOpenStages((previous) => previous ?? new Set(tree.disciplines.flatMap((item) => item.stages.map((stage) => stage.id))));
      setState("ready");
    } catch { setState("error"); }
  }, [base, canEdit, onAccessLost, workspace.id]);

  useEffect(() => { queueMicrotask(() => void load()); }, [load]);

  useEffect(() => {
    if (!draft) return;
    queueMicrotask(() => {
      if (!drawerRef.current?.contains(document.activeElement))
        drawerRef.current?.querySelector<HTMLElement>("input, select, textarea")?.focus();
    });
    const keyboard = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); closeDraft(); return; }
      if (event.key !== "Tab" || !drawerRef.current) return;
      const controls = [...drawerRef.current.querySelectorAll<HTMLElement>("button:not(:disabled), input, select, textarea")]
        .filter((element) => element.tabIndex !== -1);
      const first = controls[0]; const last = controls.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    };
    window.addEventListener("keydown", keyboard);
    return () => window.removeEventListener("keydown", keyboard);
  }, [draft]);

  function closeDraft() {
    setDraft(null);
    setFeedback("");
    queueMicrotask(() => previousFocus.current?.focus());
  }

  function rememberFocus() { previousFocus.current = document.activeElement as HTMLElement | null; }

  function toggle(id: string, level: "discipline" | "stage") {
    const update = (previous: Set<string> | null) => {
      const next = new Set(previous ?? []);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    };
    if (level === "discipline") setOpenDisciplines(update); else setOpenStages(update);
  }

  function startDiscipline(item?: Discipline) {
    rememberFocus();
    setFeedback("");
    setDraft(item ? { ...initialDraft("discipline"), id: item.id, version: item.version,
      name: item.name, shortCode: item.shortCode, color: item.color,
      displayOrder: String(item.displayOrder), description: item.description ?? "" }
      : initialDraft("discipline"));
  }
  function startStage(disciplineId: string, item?: Stage) {
    rememberFocus();
    const match = item && definitions.find((definition) => definition.code.toLowerCase() === item.code.toLowerCase());
    setFeedback("");
    setDraft(item ? { ...initialDraft("stage"), id: item.id, version: item.version, disciplineId,
      code: item.code, color: item.color, displayName: item.displayName,
      displayOrder: String(item.displayOrder), definitionId: match?.id ?? newDefinition }
      : { ...initialDraft("stage"), disciplineId });
  }
  function startActivity(disciplineId: string, stageId: string, item?: Activity) {
    rememberFocus();
    setFeedback("");
    setDraft(item ? { ...initialDraft("activity"), id: item.id, version: item.version,
      disciplineId, stageId, name: item.name, activityType: item.activityType ?? "",
      plannedStart: formatCivilDate(item.plannedStart), plannedEnd: formatCivilDate(item.plannedEnd),
      displayOrder: String(item.displayOrder), notes: item.notes ?? "" }
      : { ...initialDraft("activity"), disciplineId, stageId });
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draft || !canEdit || busy) return;
    const displayOrder = Number(draft.displayOrder);
    if (!/^\d+$/.test(draft.displayOrder) || !Number.isSafeInteger(displayOrder) || displayOrder > 1000000) {
      setFeedback(messages.scheduleInvalidOrder); return;
    }
    const plannedStart = draft.plannedStart ? parseBrazilianDate(draft.plannedStart) : null;
    const plannedEnd = draft.plannedEnd ? parseBrazilianDate(draft.plannedEnd) : null;
    if (draft.kind === "activity" && !draft.id &&
      ((!!draft.plannedStart !== !!draft.plannedEnd) ||
       (!!draft.plannedStart && (!plannedStart || !plannedEnd || plannedStart > plannedEnd)))) {
      setFeedback(messages.scheduleInvalidDates); return;
    }
    if (draft.id && !window.confirm(messages.confirmHierarchyEdit)) return;
    let path = `${base}/disciplines`;
    let data: Record<string, unknown>;
    if (draft.kind === "discipline") {
      data = { name: draft.name, shortCode: draft.shortCode, color: draft.color,
        displayOrder, description: draft.description || null };
      if (draft.id) path += `/${draft.id}`;
    } else if (draft.kind === "stage") {
      path += `/${draft.disciplineId}/stages`;
      data = { code: draft.code, color: draft.color, displayName: draft.displayName, displayOrder };
      if (draft.id) path += `/${draft.id}`;
    } else {
      path += `/${draft.disciplineId}/stages/${draft.stageId}/activities`;
      data = { name: draft.name, activityType: draft.activityType || null,
        displayOrder, notes: draft.notes || null };
      if (!draft.id) data = { ...data, plannedStart, plannedEnd };
      if (draft.id) path += `/${draft.id}`;
    }
    if (draft.id) data.version = draft.version;
    setBusy(true);
    setFeedback("");
    try {
      const result = await authenticatedFetch(path, {
        method: draft.id ? "PATCH" : "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data)
      });
      if (result.status === 401 || result.status === 403) { onAccessLost(); return; }
      if (result.status === 409) { setFeedback(messages.scheduleConflict); return; }
      if (result.status === 404) { setFeedback(messages.scheduleNotFound); return; }
      if (!result.ok) { setFeedback(messages.scheduleSaveError); return; }
      closeDraft();
      setFeedback(messages.scheduleSaved);
      await load(false);
    } catch { setFeedback(messages.scheduleSaveError); }
    finally { setBusy(false); }
  }

  function changeDefinition(id: string) {
    const selected = definitions.find((definition) => definition.id === id);
    setDraft((previous) => previous ? { ...previous, definitionId: id,
      code: selected?.code ?? "", color: selected?.color ?? "#336699" } : null);
  }

  function editRow(row: VisibleRow) {
    const discipline = hierarchy?.disciplines.find((item) => item.id === row.disciplineId);
    if (!discipline) return;
    if (row.kind === "discipline") startDiscipline(discipline);
    if (row.kind === "stage") {
      const stage = discipline.stages.find((item) => item.id === row.id);
      if (stage) startStage(discipline.id, stage);
    }
    if (row.kind === "activity") {
      const stage = discipline.stages.find((item) => item.id === row.stageId);
      const activity = stage?.activities.find((item) => item.id === row.id);
      if (stage && activity) startActivity(discipline.id, stage.id, activity);
    }
  }

  function addChild(row: VisibleRow) {
    if (row.kind === "discipline") startStage(row.id);
    if (row.kind === "stage" && row.disciplineId) startActivity(row.disciplineId, row.id);
  }

  return (
    <section className="schedule-editor" aria-labelledby="schedule-title">
      <h2 id="schedule-title">{messages.productSchedule}: {product.name}</h2>
      <button type="button" className="back-button" onClick={onBack}>{messages.backToProducts}</button>
      {state === "loading" && <p role="status">{messages.scheduleLoading}</p>}
      {state === "notFound" && <p role="alert">{messages.scheduleNotFound}</p>}
      {state === "error" && <div role="alert"><p>{messages.scheduleLoadError}</p><button type="button" onClick={() => void load()}>{messages.retry}</button></div>}
      {state === "ready" && hierarchy && (
        <>
          <div className="schedule-toolbar">
            {canEdit && <button type="button" onClick={() => startDiscipline()}>{messages.addDiscipline}</button>}
            <button type="button" onClick={() => { closeDraft(); void load(false); }}>{messages.refreshHierarchy}</button>
          </div>
          {feedback && !draft && <div role="alert" className="feedback"><p>{feedback}</p></div>}
          {hierarchy.disciplines.length === 0 && <p>{messages.noDisciplines}</p>}
          <ScheduleWorkspace product={product} tree={hierarchy} targets={targets}
            openDisciplines={openDisciplines ?? new Set()} openStages={openStages ?? new Set()}
            canEdit={canEdit} onToggle={(row) => {
              if (row.kind === "discipline" || row.kind === "stage") toggle(row.id, row.kind);
            }} onEdit={editRow} onAdd={addChild} />
        </>
      )}
      {draft && canEdit && <div className="schedule-drawer-backdrop" onMouseDown={(event) => {
        if (event.target === event.currentTarget) closeDraft();
      }}><div ref={drawerRef} className="schedule-drawer" role="dialog" aria-modal="true"
        aria-labelledby="schedule-drawer-title"><form className="hierarchy-form" onSubmit={(event) => void save(event)}>
        <h3 id="schedule-drawer-title">{draft.id ? messages.editItem : messages.newItem}</h3>
        {draft.kind === "discipline" && <>
          <label htmlFor="hierarchy-name">{messages.disciplineName}</label>
          <input id="hierarchy-name" required maxLength={200} value={draft.name}
            onChange={(event) => setDraft({ ...draft, name: event.target.value })} />
          <label htmlFor="hierarchy-code">{messages.disciplineCode}</label>
          <input id="hierarchy-code" required maxLength={24} value={draft.shortCode}
            onChange={(event) => setDraft({ ...draft, shortCode: event.target.value })} />
          <label htmlFor="hierarchy-color">{messages.color}</label>
          <input id="hierarchy-color" type="color" value={draft.color}
            onChange={(event) => setDraft({ ...draft, color: event.target.value })} />
          <label htmlFor="hierarchy-description">{messages.productDescription}</label>
          <textarea id="hierarchy-description" maxLength={2000} value={draft.description}
            onChange={(event) => setDraft({ ...draft, description: event.target.value })} />
        </>}
        {draft.kind === "stage" && <>
          <label htmlFor="stage-definition">{messages.stageDefinition}</label>
          <select id="stage-definition" value={draft.definitionId}
            onChange={(event) => changeDefinition(event.target.value)}>
            <option value={newDefinition}>{messages.newStageCode}</option>
            {definitions.map((definition) => <option key={definition.id} value={definition.id}>{definition.code}</option>)}
          </select>
          {draft.definitionId === newDefinition && <>
            <label htmlFor="stage-code">{messages.stageCode}</label>
            <input id="stage-code" required maxLength={24} value={draft.code}
              onChange={(event) => setDraft({ ...draft, code: event.target.value })} />
            <label htmlFor="stage-color">{messages.color}</label>
            <input id="stage-color" type="color" value={draft.color}
              onChange={(event) => setDraft({ ...draft, color: event.target.value })} />
          </>}
          {draft.definitionId !== newDefinition && <p>{messages.sharedStageColor(draft.color)}</p>}
          <label htmlFor="stage-name">{messages.stageName}</label>
          <input id="stage-name" required maxLength={200} value={draft.displayName}
            onChange={(event) => setDraft({ ...draft, displayName: event.target.value })} />
        </>}
        {draft.kind === "activity" && <>
          <label htmlFor="activity-name">{messages.activityName}</label>
          <input id="activity-name" required maxLength={300} value={draft.name}
            onChange={(event) => setDraft({ ...draft, name: event.target.value })} />
          <label htmlFor="activity-type">{messages.activityType}</label>
          <input id="activity-type" maxLength={80} value={draft.activityType}
            onChange={(event) => setDraft({ ...draft, activityType: event.target.value })} />
          {draft.id ? <p>{messages.existingDates}: {messages.dateRange(draft.plannedStart, draft.plannedEnd)}<br />{messages.dateChangesLater}</p>
            : <>
              <label htmlFor="activity-start">{messages.plannedStart}</label>
              <input id="activity-start" inputMode="numeric" placeholder="DD/MM/AAAA" value={draft.plannedStart}
                onChange={(event) => setDraft({ ...draft, plannedStart: event.target.value })} />
              <label htmlFor="activity-end">{messages.plannedEnd}</label>
              <input id="activity-end" inputMode="numeric" placeholder="DD/MM/AAAA" value={draft.plannedEnd}
                onChange={(event) => setDraft({ ...draft, plannedEnd: event.target.value })} />
            </>}
          <label htmlFor="activity-notes">{messages.activityNotes}</label>
          <textarea id="activity-notes" maxLength={4000} value={draft.notes}
            onChange={(event) => setDraft({ ...draft, notes: event.target.value })} />
        </>}
        <label htmlFor="hierarchy-order">{messages.displayOrder}</label>
        <input id="hierarchy-order" type="number" min={0} max={1000000} required value={draft.displayOrder}
          onChange={(event) => setDraft({ ...draft, displayOrder: event.target.value })} />
        <div className="schedule-toolbar">
          <button type="submit" disabled={busy}>{messages.save}</button>
          <button type="button" className="back-button" onClick={closeDraft}>{messages.cancel}</button>
        </div>
        {feedback && <div role="alert" className="feedback"><p>{feedback}</p>
          {feedback === messages.scheduleConflict && <button type="button" onClick={() => { closeDraft(); void load(false); }}>{messages.refreshHierarchy}</button>}
        </div>}
      </form></div></div>}
    </section>
  );
}
