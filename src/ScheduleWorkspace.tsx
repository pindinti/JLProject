import { type CSSProperties, type DragEvent, type FormEvent, type MouseEvent,
  useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { activityParentStageId, activitySiblingIds, buildActivityMoveRequest,
  type ActivityMoveRequest } from "../domain/activity-movement";
import { buildHierarchyMoveRequest, hierarchyParentId, hierarchySiblingIds,
  type HierarchyMoveKind, type HierarchyMoveRequest } from "../domain/hierarchy-movement";
import { civilFromDay, dayNumber, makeTimeline, saoPauloCivilDate, timelineDateAtPosition,
  timelineInterval, timelinePosition, visibleScheduleRows,
  type ScheduleTarget, type ScheduleTree, type VisibleRow, type Zoom } from "../domain/schedule-workspace";
import { formatCivilDate, parseBrazilianDate } from "./civil-date";
import { DatePickerField } from "./DatePickerField";
import { messages } from "./locales/pt-BR";
import { ColorField } from "./ColorField";
import { layoutMilestoneLabels } from "./design/gantt-colors";
import { rememberRecentCustomColor } from "./recent-color-history";
import type { ActivityCalendarImpact } from "../domain/calendar-impact";
import { nonWorkingDayRanges } from "../domain/non-working-day-ranges";
import { parseCivilDate, type CalendarExceptionDates } from "../domain/working-calendar";
import { authenticatedFetch } from "./auth";

const monthLabel = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });
const noCalendarImpacts: ActivityCalendarImpact[] = [];
type CalendarYearSnapshot = { version: number; exceptions: CalendarExceptionDates[] };
type DeletionTarget = { kind: "discipline" | "stage" | "activity"; id: string; label: string };
type ActivityMoveOutcome = "moved" | "unchanged" | "stale" | "invalid" | "forbidden" | "error";
type MoveDialogActivity = { id: string; label: string; sourceStageId: string | null;
  destinationStageId: string | null; position: "start" | "end" };
type MoveDialogStructure = { kind: "stage" | "discipline"; id: string; label: string;
  sourceDisciplineId: string | null; destinationDisciplineId: string | null; position: "start" | "end" };
type DropTarget = { rowKey: string; kind: HierarchyMoveKind; parentId: string | null;
  index: number; position: "before" | "after" | "append" };

export function ScheduleWorkspace({ product, tree, targets, workspaceId, openDisciplines, openStages,
  canEdit, calendarImpacts = noCalendarImpacts, onToggle, onEdit, onAdd, onAddDiscipline,
  onAddRootActivity,
  onRefresh, onHistory, onProductHistory, onRescheduleHistory, onCreateTarget, onUpdateTarget, onDeleteTarget,
  onMoveActivity = async () => "error",
  onMoveHierarchyItem = async () => "error",
  userId, onAccessLost = () => undefined }: {
  product: { id: string; name: string }; tree: ScheduleTree; targets: ScheduleTarget[]; workspaceId?: string;
  userId?: string | null;
  openDisciplines: ReadonlySet<string>; openStages: ReadonlySet<string>; canEdit: boolean;
  calendarImpacts?: ActivityCalendarImpact[];
  onToggle: (row: VisibleRow) => void; onEdit: (row: VisibleRow) => void;
  onAdd: (row: VisibleRow) => void; onHistory: (row: VisibleRow) => void;
  onAddDiscipline: () => void; onAddRootActivity?: () => void;
  onRefresh: () => void | Promise<void>; onProductHistory: () => void;
  onRescheduleHistory: () => void;
  onMoveActivity?: (request: ActivityMoveRequest) => Promise<ActivityMoveOutcome>;
  onMoveHierarchyItem?: (request: HierarchyMoveRequest) => Promise<ActivityMoveOutcome>;
  onCreateTarget: (value: { name: string; description: string | null; targetDate: string; color: string }) => Promise<ScheduleTarget>;
  onUpdateTarget: (target: ScheduleTarget, value: { name: string; description: string | null;
    targetDate: string; color: string; reason: string | null }) => Promise<ScheduleTarget>;
  onDeleteTarget: (target: ScheduleTarget) => Promise<void>;
  onAccessLost?: () => void;
}) {
  const [zoom, setZoom] = useState<Zoom>("week");
  const [tableWidth, setTableWidth] = useState(50);
  const [selected, setSelected] = useState<string | null>(null);
  const [hoveredRowKey, setHoveredRowKey] = useState<string | null>(null);
  const hoverClearTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [selectedDate, setSelectedDate] = useState<string | null>(null);
  const [today, setToday] = useState(() => saoPauloCivilDate(new Date()));
  const [bounds, setBounds] = useState(() => {
    const initial = makeTimeline(tree, targets, "week", today);
    return { startDay: initial.startDay, endDay: initial.endDay };
  });
  const [productExpanded, setProductExpanded] = useState(true);
  const [mobilePane, setMobilePane] = useState<"table" | "gantt">("table");
  const [targetDialog, setTargetDialog] = useState<ScheduleTarget | "new" | null>(null);
  const [deletionTarget, setDeletionTarget] = useState<DeletionTarget | null>(null);
  const [deletionPreview, setDeletionPreview] = useState<{ fingerprint: string;
    counts: { disciplines: number; stages: number; activities: number } } | null>(null);
  const [deletionReason, setDeletionReason] = useState("");
  const [deletionError, setDeletionError] = useState("");
  const [deletionLoading, setDeletionLoading] = useState(false);
  const [deletionBusy, setDeletionBusy] = useState(false);
  const [deletionStale, setDeletionStale] = useState(false);
  const deletionSubmitting = useRef(false);
  const deletionRequest = useRef(0);
  const deletionTrigger = useRef<HTMLButtonElement | null>(null);
  const deletionDialog = useRef<HTMLDivElement>(null);
  const [draggedActivityId, setDraggedActivityId] = useState<string | null>(null);
  const [draggedStructureItem, setDraggedStructureItem] = useState<{ kind: "stage" | "discipline"; id: string } | null>(null);
  const [dropTarget, setDropTarget] = useState<DropTarget | null>(null);
  const [moveDialog, setMoveDialog] = useState<MoveDialogActivity | null>(null);
  const [structureMoveDialog, setStructureMoveDialog] = useState<MoveDialogStructure | null>(null);
  const [moveBusy, setMoveBusy] = useState(false);
  const [moveFeedback, setMoveFeedback] = useState("");
  const [moveFeedbackIsError, setMoveFeedbackIsError] = useState(false);
  const moveSubmitting = useRef(false);
  const moveTrigger = useRef<HTMLButtonElement | null>(null);
  const moveDialogElement = useRef<HTMLDivElement>(null);
  const [calendarExceptionsByYear, setCalendarExceptionsByYear] = useState<Record<number, CalendarYearSnapshot | null>>({});
  const splitRef = useRef<HTMLDivElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<HTMLDivElement>(null);
  const scrollbarRef = useRef<HTMLDivElement>(null);
  const centerDateAfterScale = useRef<string | null>(null);
  const dragging = useRef(false);
  useEffect(() => () => {
    if (hoverClearTimer.current !== null) clearTimeout(hoverClearTimer.current);
  }, []);
  const rows = useMemo(() => visibleScheduleRows(product, tree, openDisciplines, openStages, productExpanded),
    [product, tree, openDisciplines, openStages, productExpanded]);
  const dropRow = dropTarget ? rows.find((row) => row.key === dropTarget.rowKey) : undefined;
  const dropAnnouncement = !dropTarget ? draggedStructureItem
    ? messages.hierarchyMoveDragInstructions(draggedStructureItem.kind)
    : messages.activityMoveDragInstructions
    : dropTarget.kind === "activity" ? dropTarget.position === "before"
      ? messages.activityMoveDropBefore(dropRow?.label ?? "")
      : dropTarget.position === "after" ? messages.activityMoveDropAfter(dropRow?.label ?? "")
        : dropTarget.parentId === null ? messages.activityMoveDropAppendRoot
          : messages.activityMoveDropAppendStage(dropRow?.label ?? "")
      : dropTarget.position === "before" ? messages.hierarchyMoveDropBefore(dropTarget.kind, dropRow?.label ?? "")
        : dropTarget.position === "after" ? messages.hierarchyMoveDropAfter(dropTarget.kind, dropRow?.label ?? "")
          : messages.stageMoveDropAppend(dropRow?.label ?? "");
  function dropTargetFor(row: VisibleRow, event?: DragEvent<HTMLDivElement>): DropTarget | null {
    if (!canEdit || moveBusy) return null;
    if (draggedStructureItem) {
      const { kind, id } = draggedStructureItem;
      let parentId: string | null;
      let position: DropTarget["position"] = "append";
      if (kind === "discipline") {
        if (row.kind !== "discipline" || row.id === id) return null;
        parentId = null;
        position = event && event.clientY > event.currentTarget.getBoundingClientRect().top +
          event.currentTarget.getBoundingClientRect().height / 2 ? "after" : "before";
      } else if (row.kind === "discipline") {
        parentId = row.id;
      } else if (row.kind === "stage") {
        if (row.id === id) return null;
        const parent = hierarchyParentId(tree, "stage", row.id);
        if (parent === undefined) return null;
        parentId = parent;
        position = event && event.clientY > event.currentTarget.getBoundingClientRect().top +
          event.currentTarget.getBoundingClientRect().height / 2 ? "after" : "before";
      } else return null;
      const siblingIds = hierarchySiblingIds(tree, kind, parentId);
      if (!siblingIds) return null;
      const remaining = siblingIds.filter((siblingId) => siblingId !== id);
      if (row.kind === kind) {
        const targetIndex = remaining.indexOf(row.id);
        if (targetIndex < 0) return null;
        return { rowKey: row.key, kind, parentId,
          index: targetIndex + (position === "after" ? 1 : 0), position };
      }
      return { rowKey: row.key, kind, parentId, index: remaining.length, position };
    }
    if (!draggedActivityId) return null;
    let stageId: string | null;
    let position: DropTarget["position"] = "append";
    if (row.kind === "product") stageId = null;
    else if (row.kind === "stage") stageId = row.id;
    else if (row.kind === "activity") {
      stageId = row.stageId ?? null;
      if (row.id === draggedActivityId) return null;
      position = event && event.clientY > event.currentTarget.getBoundingClientRect().top +
        event.currentTarget.getBoundingClientRect().height / 2 ? "after" : "before";
    } else return null;
    const siblingIds = activitySiblingIds(tree, stageId);
    if (!siblingIds) return null;
    const remaining = siblingIds.filter((id) => id !== draggedActivityId);
    if (row.kind === "activity") {
      const targetIndex = remaining.indexOf(row.id);
      if (targetIndex < 0) return null;
      return { rowKey: row.key, kind: "activity", parentId: stageId,
        index: targetIndex + (position === "after" ? 1 : 0), position };
    }
    return { rowKey: row.key, kind: "activity", parentId: stageId, index: remaining.length, position };
  }

  async function submitActivityMove(activityId: string, stageId: string | null, index: number) {
    if (!canEdit || moveSubmitting.current) return;
    const request = buildActivityMoveRequest(tree, activityId, stageId, index);
    if (!request) {
      setMoveFeedback(messages.activityMoveInvalid);
      setMoveFeedbackIsError(true);
      return;
    }
    moveSubmitting.current = true;
    setMoveBusy(true);
    setMoveFeedback("");
    setMoveFeedbackIsError(false);
    try {
      const outcome = await onMoveActivity(request);
      if (outcome === "moved" || outcome === "unchanged") {
        setMoveDialog(null);
        setMoveFeedback(outcome === "moved" ? messages.activityMoveSuccess : messages.activityMoveUnchanged);
        setMoveFeedbackIsError(false);
        queueMicrotask(() => moveTrigger.current?.focus());
      } else {
        const message = outcome === "stale" ? messages.activityMoveStale
          : outcome === "invalid" ? messages.activityMoveInvalid
            : outcome === "forbidden" ? messages.activityMovePermissionError : messages.activityMoveError;
        setMoveFeedback(message);
        setMoveFeedbackIsError(true);
      }
    } catch {
      setMoveFeedback(messages.activityMoveError);
      setMoveFeedbackIsError(true);
    } finally {
      moveSubmitting.current = false;
      setMoveBusy(false);
      setDraggedActivityId(null);
      setDraggedStructureItem(null);
      setDropTarget(null);
    }
  }

  function structureMoveMessage(kind: "stage" | "discipline", outcome: ActivityMoveOutcome): string {
    if (outcome === "moved") return messages.hierarchyMoveSuccess(kind);
    if (outcome === "unchanged") return messages.hierarchyMoveUnchanged(kind);
    if (outcome === "stale") return messages.hierarchyMoveStale;
    if (outcome === "invalid") return messages.hierarchyMoveInvalid(kind);
    if (outcome === "forbidden") return messages.hierarchyMovePermissionError(kind);
    return messages.hierarchyMoveError(kind);
  }

  async function submitStructureMove(kind: "stage" | "discipline", id: string,
    destinationDisciplineId: string | null, index: number) {
    if (!canEdit || moveSubmitting.current) return;
    const request = buildHierarchyMoveRequest(tree, kind, id, destinationDisciplineId, index);
    if (!request) {
      setMoveFeedback(messages.hierarchyMoveInvalid(kind));
      setMoveFeedbackIsError(true);
      return;
    }
    moveSubmitting.current = true;
    setMoveBusy(true);
    setMoveFeedback(messages.hierarchyMoveSubmitting(kind));
    setMoveFeedbackIsError(false);
    try {
      const outcome = await onMoveHierarchyItem(request);
      if (outcome === "moved" || outcome === "unchanged") {
        setStructureMoveDialog(null);
        setMoveFeedback(structureMoveMessage(kind, outcome));
        setMoveFeedbackIsError(false);
        queueMicrotask(() => moveTrigger.current?.focus());
      } else {
        setMoveFeedback(structureMoveMessage(kind, outcome));
        setMoveFeedbackIsError(true);
      }
    } catch {
      setMoveFeedback(messages.hierarchyMoveError(kind));
      setMoveFeedbackIsError(true);
    } finally {
      moveSubmitting.current = false;
      setMoveBusy(false);
      setDraggedActivityId(null);
      setDraggedStructureItem(null);
      setDropTarget(null);
    }
  }

  function startActivityDrag(event: DragEvent<HTMLButtonElement>, row: VisibleRow) {
    if (!canEdit || moveBusy || activityParentStageId(tree, row.id) === undefined) {
      event.preventDefault();
      return;
    }
    event.stopPropagation();
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", row.id);
    setMoveFeedback("");
    setMoveFeedbackIsError(false);
    setDraggedStructureItem(null);
    setDraggedActivityId(row.id);
    setDropTarget(null);
  }

  function startStructureDrag(event: DragEvent<HTMLButtonElement>, row: VisibleRow) {
    if (!canEdit || moveBusy || (row.kind !== "stage" && row.kind !== "discipline") ||
        hierarchyParentId(tree, row.kind, row.id) === undefined) {
      event.preventDefault();
      return;
    }
    event.stopPropagation();
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", `${row.kind}:${row.id}`);
    setMoveFeedback("");
    setMoveFeedbackIsError(false);
    setDraggedActivityId(null);
    setDraggedStructureItem({ kind: row.kind, id: row.id });
    setDropTarget(null);
  }

  function openActivityMoveDialog(row: VisibleRow, trigger: HTMLButtonElement) {
    if (!canEdit || row.kind !== "activity" || moveBusy) return;
    const sourceStageId = activityParentStageId(tree, row.id);
    if (sourceStageId === undefined) {
      setMoveFeedback(messages.activityMoveInvalid);
      setMoveFeedbackIsError(true);
      return;
    }
    moveTrigger.current = trigger;
    setMoveFeedback("");
    setMoveFeedbackIsError(false);
    setMoveDialog({ id: row.id, label: row.label, sourceStageId,
      destinationStageId: sourceStageId, position: "end" });
    setStructureMoveDialog(null);
  }

  function openStructureMoveDialog(row: VisibleRow, trigger: HTMLButtonElement) {
    if (!canEdit || (row.kind !== "stage" && row.kind !== "discipline") || moveBusy) return;
    const sourceDisciplineId = hierarchyParentId(tree, row.kind, row.id);
    if (sourceDisciplineId === undefined) {
      setMoveFeedback(messages.hierarchyMoveInvalid(row.kind));
      setMoveFeedbackIsError(true);
      return;
    }
    moveTrigger.current = trigger;
    setMoveFeedback("");
    setMoveFeedbackIsError(false);
    setMoveDialog(null);
    setStructureMoveDialog({ kind: row.kind, id: row.id, label: row.label, sourceDisciplineId,
      destinationDisciplineId: sourceDisciplineId, position: "end" });
  }

  function closeMoveDialog() {
    if (moveBusy) return;
    setMoveDialog(null);
    setStructureMoveDialog(null);
    queueMicrotask(() => moveTrigger.current?.focus());
  }

  function submitActivityMoveDialog(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!moveDialog || moveBusy) return;
    const siblingIds = activitySiblingIds(tree, moveDialog.destinationStageId);
    const sourceStageId = activityParentStageId(tree, moveDialog.id);
    if (!siblingIds || sourceStageId === undefined) {
      setMoveFeedback(messages.activityMoveInvalid);
      setMoveFeedbackIsError(true);
      return;
    }
    const maximumIndex = siblingIds.length - (sourceStageId === moveDialog.destinationStageId ? 1 : 0);
    const index = moveDialog.position === "start" ? 0 : maximumIndex;
    void submitActivityMove(moveDialog.id, moveDialog.destinationStageId, index);
  }

  function submitStructureMoveDialog(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!structureMoveDialog || moveBusy) return;
    const parentId = structureMoveDialog.kind === "stage" ? structureMoveDialog.destinationDisciplineId : null;
    const siblings = hierarchySiblingIds(tree, structureMoveDialog.kind, parentId);
    const sourceParentId = hierarchyParentId(tree, structureMoveDialog.kind, structureMoveDialog.id);
    if (!siblings || sourceParentId === undefined ||
        (structureMoveDialog.kind === "stage" && parentId === null)) {
      setMoveFeedback(messages.hierarchyMoveInvalid(structureMoveDialog.kind));
      setMoveFeedbackIsError(true);
      return;
    }
    const maximumIndex = siblings.length - (sourceParentId === parentId ? 1 : 0);
    const index = structureMoveDialog.position === "start" ? 0 : maximumIndex;
    void submitStructureMove(structureMoveDialog.kind, structureMoveDialog.id, parentId, index);
  }

  useEffect(() => {
    if (!moveDialog && !structureMoveDialog) return;
    const dialog = moveDialogElement.current;
    queueMicrotask(() => dialog?.querySelector<HTMLElement>("select, button")?.focus());
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape" && !moveSubmitting.current) {
        event.preventDefault();
        setMoveDialog(null);
        setStructureMoveDialog(null);
        queueMicrotask(() => moveTrigger.current?.focus());
        return;
      }
      if (event.key !== "Tab" || !dialog) return;
      const controls = [...dialog.querySelectorAll<HTMLElement>("button:not(:disabled), select:not(:disabled)")];
      if (controls.length === 0) return;
      if (event.shiftKey && document.activeElement === controls[0]) {
        event.preventDefault(); controls[controls.length - 1]?.focus();
      } else if (!event.shiftKey && document.activeElement === controls[controls.length - 1]) {
        event.preventDefault(); controls[0]?.focus();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [moveDialog, structureMoveDialog]);

  const scale = useMemo(() => {
    const previewBounds = { ...bounds };
    for (const impact of calendarImpacts) {
      if (impact.impact !== "date_change") continue;
      previewBounds.startDay = Math.min(previewBounds.startDay, dayNumber(impact.proposedStartDate) - 14);
      previewBounds.endDay = Math.max(previewBounds.endDay, dayNumber(impact.proposedEndDate) + 14);
    }
    return makeTimeline(tree, targets, zoom, today, previewBounds);
  }, [tree, targets, zoom, today, bounds, calendarImpacts]);
  const calendarYears = useMemo(() => {
    const first = parseCivilDate(civilFromDay(scale.startDay))?.year;
    const last = parseCivilDate(civilFromDay(scale.endDay))?.year;
    if (first === undefined || last === undefined) return [];
    return Array.from({ length: last - first + 1 }, (_, index) => first + index)
      .filter((year) => year >= 2026 && year <= 2100);
  }, [scale.startDay, scale.endDay]);
  const calendarYearKey = calendarYears.join(",");
  useEffect(() => {
    if (!workspaceId || !calendarYearKey) return;
    const years = calendarYearKey.split(",").map(Number).filter((year) => !(year in calendarExceptionsByYear));
    if (years.length === 0) return;
    let active = true;
    void Promise.all(years.map(async (year): Promise<[number, CalendarYearSnapshot | null]> => {
      try {
        const response = await authenticatedFetch(`/api/workspaces/${workspaceId}/calendar?year=${year}`);
        if (!response.ok) return [year, null];
        const payload = await response.json() as { calendar?: { version?: unknown; exceptions?: unknown } };
        if (!Number.isSafeInteger(payload.calendar?.version) || !Array.isArray(payload.calendar?.exceptions)) return [year, null];
        const exceptions = payload.calendar.exceptions.filter((item): item is CalendarExceptionDates => {
          if (!item || typeof item !== "object") return false;
          const candidate = item as Partial<CalendarExceptionDates>;
          return ["municipal_holiday", "collective_vacation", "company_shutdown"].includes(candidate.kind ?? "") &&
            typeof candidate.startDate === "string" && !!parseCivilDate(candidate.startDate) &&
            typeof candidate.endDate === "string" && !!parseCivilDate(candidate.endDate) &&
            candidate.startDate <= candidate.endDate;
        });
        return [year, { version: Number(payload.calendar?.version), exceptions }];
      } catch { return [year, null]; }
    })).then((results) => {
      if (active) setCalendarExceptionsByYear((current) => ({ ...current, ...Object.fromEntries(results) }));
    });
    return () => { active = false; };
  }, [workspaceId, calendarYearKey, calendarExceptionsByYear]);
  const calendarExceptions = useMemo(() => calendarYears.flatMap((year) => calendarExceptionsByYear[year]?.exceptions ?? []),
    [calendarYears, calendarExceptionsByYear]);
  const calendarLoading = !!workspaceId && calendarYears.some((year) => !(year in calendarExceptionsByYear));
  const calendarVersions = new Set(calendarYears.map((year) => calendarExceptionsByYear[year]?.version)
    .filter((version): version is number => version !== undefined));
  const calendarFailed = !!workspaceId && (calendarYears.some((year) => calendarExceptionsByYear[year] === null) || calendarVersions.size > 1);
  const nonWorkingRanges = useMemo(() => nonWorkingDayRanges(scale.startDay, scale.endDay, calendarExceptions),
    [scale.startDay, scale.endDay, calendarExceptions]);
  const impactByActivity = useMemo(() => new Map(calendarImpacts.filter((impact) =>
    impact.impact === "date_change").map((impact) => [impact.activityId, impact])), [calendarImpacts]);
  const milestoneLabels = useMemo(() => layoutMilestoneLabels(targets,
    (date) => timelinePosition(scale, date), scale.width), [targets, scale]);
  const milestoneLaneCount = milestoneLabels.reduce((count, label) => Math.max(count, label.lane + 1), 0);
  const targetHeadHeight = Math.max(29, milestoneLaneCount * 18 + 22);
  const headerHeight = Math.max(82, 28 + 24 + targetHeadHeight);

  async function fetchDeletionPreview(target: DeletionTarget,
    resetReason: boolean) {
    const requestId = ++deletionRequest.current;
    if (resetReason) setDeletionReason("");
    setDeletionPreview(null);
    setDeletionStale(false);
    setDeletionError("");
    setDeletionLoading(true);
    if (!workspaceId) {
      setDeletionError(messages.scheduleDeletionPreviewError);
      setDeletionLoading(false);
      return;
    }
    const query = new URLSearchParams({ kind: target.kind, targetId: target.id });
    try {
      const result = await authenticatedFetch(`/api/workspaces/${workspaceId}/products/${product.id}/hierarchy/deletion-preview?${query}`);
      if (requestId !== deletionRequest.current) return;
      if (result.status === 401 || result.status === 403) {
        onAccessLost();
        setDeletionError(messages.scheduleDeletionPermissionError);
        return;
      }
      if (result.status === 404) {
        setDeletionError(messages.scheduleDeletionNotFound);
        return;
      }
      if (!result.ok) throw new Error("Deletion preview failed.");
      const value = await result.json() as { fingerprint?: unknown;
        counts?: Partial<{ disciplines: number; stages: number; activities: number }> };
      if (typeof value.fingerprint !== "string" || !/^[0-9a-f]{32}$/.test(value.fingerprint) ||
          !value.counts || ![value.counts.disciplines, value.counts.stages, value.counts.activities]
            .every((count) => Number.isSafeInteger(count) && Number(count) >= 0))
        throw new Error("Invalid deletion preview.");
      setDeletionPreview({ fingerprint: value.fingerprint, counts: {
        disciplines: Number(value.counts.disciplines), stages: Number(value.counts.stages),
        activities: Number(value.counts.activities)
      } });
    } catch {
      if (requestId === deletionRequest.current) setDeletionError(messages.scheduleDeletionPreviewError);
    } finally {
      if (requestId === deletionRequest.current) setDeletionLoading(false);
    }
  }

  function startDeletion(row: VisibleRow, trigger: HTMLButtonElement) {
    if (!canEdit || row.kind === "product" || deletionBusy) return;
    deletionTrigger.current = trigger;
    const target: DeletionTarget = { kind: row.kind, id: row.id, label: row.label };
    setDeletionTarget(target);
    void fetchDeletionPreview(target, true);
  }

  async function confirmDeletion(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canEdit || !deletionTarget || !deletionPreview || deletionStale || deletionSubmitting.current) return;
    const reason = deletionReason.trim();
    if (reason.length < 10) {
      setDeletionError(messages.scheduleDeletionReasonHint);
      return;
    }
    deletionSubmitting.current = true;
    setDeletionBusy(true);
    setDeletionError("");
    try {
      const result = await authenticatedFetch(`/api/workspaces/${workspaceId}/products/${product.id}/hierarchy/deletions`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind: deletionTarget.kind, targetId: deletionTarget.id,
          fingerprint: deletionPreview.fingerprint, reason })
      });
      if (result.status === 401 || result.status === 403) {
        onAccessLost();
        setDeletionError(messages.scheduleDeletionPermissionError);
        return;
      }
      if (result.status === 404) {
        setDeletionError(messages.scheduleDeletionNotFound);
        return;
      }
      if (result.status === 409) {
        setDeletionStale(true);
        setDeletionError(messages.scheduleDeletionConflict);
        return;
      }
      if (result.status === 400) {
        setDeletionError(messages.scheduleDeletionInvalid);
        return;
      }
      if (!result.ok) throw new Error("Deletion request failed.");
      setDeletionTarget(null);
      setDeletionPreview(null);
      setSelected(null);
      await onRefresh();
      document.querySelector<HTMLElement>(".workspace-table-rows")?.focus();
    } catch {
      setDeletionError(messages.scheduleDeletionSaveError);
    } finally {
      deletionSubmitting.current = false;
      setDeletionBusy(false);
    }
  }

  useEffect(() => {
    if (!deletionTarget) return;
    const dismiss = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !deletionSubmitting.current) {
        event.preventDefault();
        deletionRequest.current++;
        setDeletionTarget(null);
        setDeletionPreview(null);
        queueMicrotask(() => deletionTrigger.current?.focus());
      }
    };
    document.addEventListener("keydown", dismiss);
    return () => document.removeEventListener("keydown", dismiss);
  }, [deletionTarget]);

  useEffect(() => {
    if (deletionTarget) deletionDialog.current?.querySelector<HTMLElement>("button, textarea")?.focus();
  }, [deletionTarget, deletionLoading, deletionPreview]);

  useEffect(() => {
    if (scale.startDay !== bounds.startDay || scale.endDay !== bounds.endDay)
      queueMicrotask(() => setBounds({ startDay: scale.startDay, endDay: scale.endDay }));
  }, [scale.startDay, scale.endDay, bounds.startDay, bounds.endDay]);

  useEffect(() => {
    const refresh = () => setToday(saoPauloCivilDate(new Date()));
    const timer = window.setInterval(refresh, 30_000);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, []);

  useLayoutEffect(() => {
    const date = centerDateAfterScale.current;
    const scrollbar = scrollbarRef.current;
    const chart = chartRef.current;
    if (date && scrollbar && chart) {
      const viewportWidth = chart.clientWidth || scrollbar.clientWidth;
      const desiredPosition = timelinePosition(scale, date) + scale.dayWidth / 2 - viewportWidth / 2;
      scrollbar.scrollLeft = Math.max(0, Math.min(scrollbar.scrollWidth - scrollbar.clientWidth, desiredPosition));
      centerDateAfterScale.current = null;
    }
    const position = scrollbar?.scrollLeft ?? 0;
    if (headerRef.current) headerRef.current.scrollLeft = position;
    if (chart) chart.scrollLeft = position;
  }, [scale, tableWidth]);

  useEffect(() => {
    const move = (event: PointerEvent) => {
      if (!dragging.current || !splitRef.current) return;
      const box = splitRef.current.getBoundingClientRect();
      setTableWidth(Math.min(70, Math.max(30, Math.round((event.clientX - box.left) / box.width * 100))));
    };
    const stop = () => { dragging.current = false; };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", stop);
    return () => { window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", stop); };
  }, []);

  function syncScroll(source: "header" | "chart" | "scrollbar") {
    const elements = { header: headerRef.current, chart: chartRef.current, scrollbar: scrollbarRef.current };
    const position = elements[source]?.scrollLeft;
    if (position === undefined) return;
    for (const element of Object.values(elements)) {
      if (element && element.scrollLeft !== position) element.scrollLeft = position;
    }
  }

  function shiftTimeline(direction: -1 | 1) {
    if (!scrollbarRef.current) return;
    scrollbarRef.current.scrollLeft += direction * 300;
    syncScroll("scrollbar");
  }

  function scrollTimelineToDate(date: string, timeline: typeof scale) {
    const scrollbar = scrollbarRef.current;
    const chart = chartRef.current;
    if (!scrollbar || !chart) return;
    const viewportWidth = chart.clientWidth || scrollbar.clientWidth;
    const desiredPosition = timelinePosition(timeline, date) + timeline.dayWidth / 2 - viewportWidth / 2;
    scrollbar.scrollLeft = Math.max(0, Math.min(scrollbar.scrollWidth - scrollbar.clientWidth, desiredPosition));
    syncScroll("scrollbar");
  }

  function goToToday() {
    const date = saoPauloCivilDate(new Date());
    setToday(date);
    setSelectedDate(date);
    const chart = chartRef.current;
    const scrollbar = scrollbarRef.current;
    if (!chart || !scrollbar) return;
    const viewportWidth = chart.clientWidth || scrollbar.clientWidth;
    if (viewportWidth > 0) {
      const halfVisibleDays = Math.ceil(viewportWidth / (2 * scale.dayWidth));
      const todayDay = dayNumber(date);
      const nextBounds = {
        startDay: Math.min(bounds.startDay, todayDay - halfVisibleDays),
        endDay: Math.max(bounds.endDay, todayDay + halfVisibleDays)
      };
      if (nextBounds.startDay !== bounds.startDay || nextBounds.endDay !== bounds.endDay) {
        centerDateAfterScale.current = date;
        setBounds(nextBounds);
        return;
      }
    }
    scrollTimelineToDate(date, scale);
  }

  function selectDate(event: MouseEvent<HTMLDivElement>) {
    const element = event.currentTarget;
    const position = event.clientX - element.getBoundingClientRect().left + element.scrollLeft;
    setSelectedDate(timelineDateAtPosition(scale, position));
  }

  function changeSelectedDate(direction: -1 | 1) {
    const day = dayNumber(selectedDate ?? today) + direction;
    setSelectedDate(civilFromDay(Math.max(scale.startDay, Math.min(scale.endDay, day))));
  }

  function enterRow(rowKey: string) {
    if (hoverClearTimer.current !== null) clearTimeout(hoverClearTimer.current);
    hoverClearTimer.current = null;
    setHoveredRowKey((current) => current === rowKey ? current : rowKey);
  }

  function leaveRow(rowKey: string) {
    if (hoverClearTimer.current !== null) clearTimeout(hoverClearTimer.current);
    hoverClearTimer.current = setTimeout(() => {
      hoverClearTimer.current = null;
      setHoveredRowKey((current) => current === rowKey ? null : current);
    }, 40);
  }

  const style = { "--table-width": `${tableWidth}%` } as CSSProperties;
  return <section className="schedule-workspace" data-density="compact" aria-label={messages.scheduleWorkspace}>
    {moveFeedback && <p className={moveFeedbackIsError ? "activity-move-feedback activity-move-feedback--error" : "activity-move-feedback"}
      role={moveFeedbackIsError ? "alert" : "status"}>{moveFeedback}</p>}
    {(draggedActivityId || draggedStructureItem) && <p className="activity-move-live" role="status" aria-live="polite">
      {dropAnnouncement}
    </p>}
    <div className="workspace-controls">
      <div className="workspace-toolbar-actions">
        {canEdit && <button type="button" onClick={onAddDiscipline}>{messages.addDiscipline}</button>}
        <button type="button" onClick={() => { setCalendarExceptionsByYear({}); onRefresh(); }}>{messages.refreshHierarchy}</button>
        <button type="button" onClick={onProductHistory}>{messages.productHistoryOpen}</button>
        <button type="button" onClick={onRescheduleHistory}>{messages.calendarRescheduleHistory}</button>
      </div>
      <div className="workspace-zoom" role="group" aria-label={messages.scheduleZoom}>
        {([ ["day", messages.zoomDay], ["week", messages.zoomWeek], ["month", messages.zoomMonth] ] as const).map(([value, label]) =>
          <button key={value} type="button" aria-pressed={zoom === value}
            onClick={() => setZoom(value)}>{label}</button>)}
      </div>
      <div className="workspace-timeline-navigation" role="group" aria-label={messages.scheduleTimeline}>
        <button type="button" className="timeline-navigation" onClick={() => shiftTimeline(-1)}>{messages.timelineEarlier}</button>
        <button type="button" className="timeline-navigation" onClick={() => shiftTimeline(1)}>{messages.timelineLater}</button>
        <button type="button" className="timeline-navigation" aria-label={messages.goToToday}
          title={messages.goToToday} onClick={goToToday}>{messages.today}</button>
      </div>
      {calendarLoading && <span className="calendar-highlight-status" role="status">{messages.calendarHighlightLoading}</span>}
      {calendarFailed && <span className="calendar-highlight-status" role="status">
        {messages.calendarHighlightError}{" "}
        <button type="button" onClick={() => setCalendarExceptionsByYear((current) => {
          const next = { ...current };
          for (const year of calendarYears) delete next[year];
          return next;
        })}>{messages.calendarHighlightRetry}</button>
      </span>}
      {selectedDate && <span role="status" className="workspace-selected-date">
        {messages.selectedDate(formatCivilDate(selectedDate))}
        <button type="button" onClick={() => setSelectedDate(null)}>{messages.clearSelectedDate}</button>
      </span>}
      {canEdit && <button type="button" onClick={() => setTargetDialog("new")}>{messages.addMilestone}</button>}
      <span>{messages.targetCount(targets.length)}</span>
      <div className="workspace-mobile-switch" role="group" aria-label={messages.schedulePane}>
        <button type="button" aria-pressed={mobilePane === "table"} onClick={() => setMobilePane("table")}>{messages.scheduleTable}</button>
        <button type="button" aria-pressed={mobilePane === "gantt"} onClick={() => setMobilePane("gantt")}>{messages.scheduleGantt}</button>
      </div>
    </div>
    <div ref={splitRef} className={`workspace-split mobile-${mobilePane}`} style={style}>
      <div className="workspace-headers" style={{ height: headerHeight, flexBasis: headerHeight }}>
        <div className="workspace-table-header" style={{ height: headerHeight }}>
          <span>{messages.scheduleItem}</span><span>{messages.plannedStart}</span>
          <span>{messages.plannedEnd}</span>
        </div>
        <div className="workspace-divider-header" />
        <div ref={headerRef} className="workspace-timeline-header" onScroll={() => syncScroll("header")}
          onClick={selectDate} onKeyDown={(event) => {
            if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
              event.preventDefault();
              changeSelectedDate(event.key === "ArrowLeft" ? -1 : 1);
            }
          }} tabIndex={0} role="group" aria-label={messages.timelineDateInstructions}>
          <div className="timeline-head-content" style={{ width: scale.width, height: headerHeight }}>
            <div className="timeline-months">{scale.months.map((month) => <div key={month.startDay}
              className="timeline-month" style={{ width: month.days * scale.dayWidth }}>
              {monthLabel.format(new Date(month.startDay * 86_400_000))}
            </div>)}</div>
            <div className="timeline-ticks">{scale.ticks.map((day) => <span key={day} className="timeline-tick"
              style={{ left: (day - scale.startDay) * scale.dayWidth }}>
              {zoom === "month" ? formatCivilDate(civilFromDay(day)).slice(3) : formatCivilDate(civilFromDay(day)).slice(0, 5)}
            </span>)}</div>
            <div className="timeline-target-head" style={{ height: targetHeadHeight }}>
              {milestoneLabels.map((label) => {
                const target = targets.find((item) => item.id === label.id);
                if (!target) return null;
                return <button type="button" key={target.id} className="timeline-target-label"
                  style={{ left: label.left, top: 2 + label.lane * 18, width: label.width, color: target.color }}
                  title={messages.targetDetail(target.name, formatCivilDate(target.targetDate))}
                  aria-label={`${messages.targetDetail(target.name, formatCivilDate(target.targetDate))}. ${canEdit ? messages.edit : messages.milestoneView}`}
                  onClick={(event) => { event.stopPropagation(); setTargetDialog(target); }}>
                  {label.name}
                </button>;
              })}
              <span className="timeline-today-label" style={{ left: timelinePosition(scale, today), top: targetHeadHeight - 17 }}
                title={`${messages.today}: ${formatCivilDate(today)}`}>{messages.today}</span>
            </div>
          </div>
        </div>
      </div>
      <div className="workspace-body">
        <div className="workspace-table-rows" role="table" aria-label={messages.scheduleTable} tabIndex={-1}>
          {rows.map((row) => {
            const isDropTarget = dropTarget?.rowKey === row.key;
            const dropClass = isDropTarget ? ` drop-${dropTarget.position}` : "";
            return <div key={row.key} className={`workspace-table-row row-${row.kind}${selected === row.key ? " selected" : ""}${hoveredRowKey === row.key ? " is-hovered" : ""}${dropClass}`}
              data-row-key={row.key} role="row" aria-selected={selected === row.key}
              onMouseEnter={() => enterRow(row.key)} onMouseLeave={() => leaveRow(row.key)}
              onDragOver={(event) => {
                const candidate = dropTargetFor(row, event);
                if (!candidate) return;
                event.preventDefault();
                event.dataTransfer.dropEffect = "move";
                setDropTarget(candidate);
              }}
              onDragLeave={(event) => {
                if (event.currentTarget.contains(event.relatedTarget as Node)) return;
                setDropTarget((current) => current?.rowKey === row.key ? null : current);
              }}
              onDrop={(event) => {
                event.preventDefault();
                event.stopPropagation();
                const candidate = dropTargetFor(row, event);
                if (candidate && draggedActivityId && candidate.kind === "activity")
                  void submitActivityMove(draggedActivityId, candidate.parentId, candidate.index);
                else if (candidate && draggedStructureItem && candidate.kind === draggedStructureItem.kind)
                  void submitStructureMove(draggedStructureItem.kind, draggedStructureItem.id, candidate.parentId, candidate.index);
                else if (draggedActivityId || draggedStructureItem) {
                  setMoveFeedback(draggedStructureItem
                    ? messages.hierarchyMoveInvalid(draggedStructureItem.kind) : messages.activityMoveInvalid);
                  setMoveFeedbackIsError(true);
                }
                setDraggedActivityId(null);
                setDraggedStructureItem(null);
                setDropTarget(null);
              }}>
            <div role="cell" className="workspace-name-cell" style={{ paddingLeft: `${
              row.kind === "activity" && !row.disciplineId ? 12
                : ({ product: 0, discipline: 12, stage: 27, activity: 42 })[row.kind]
            }px` }}>
              {row.hasChildren && <button type="button" className="workspace-expand" aria-expanded={row.expanded}
                aria-label={messages.toggleScheduleRow(row.label)} onClick={() => {
                  if (row.kind === "product") setProductExpanded((value) => !value);
                  else onToggle(row);
                }}>
                {row.expanded ? "▾" : "▸"}
              </button>}
              {!row.hasChildren && <span className="workspace-expand-spacer" />}
              {row.color && <span className="color-chip" style={{ backgroundColor: row.color }}
                aria-label={messages.scheduleColor(row.color)} />}
              <span className="workspace-inline-actions">
                {canEdit && row.kind === "activity" && <button type="button" className="workspace-icon-action workspace-icon-action--move"
                  draggable={!moveBusy} disabled={moveBusy}
                  aria-label={messages.activityMoveHandle(row.label)} title={messages.activityMoveHandle(row.label)}
                  onClick={(event) => { event.stopPropagation(); openActivityMoveDialog(row, event.currentTarget); }}
                  onDragStart={(event) => startActivityDrag(event, row)}
                  onDragEnd={() => { setDraggedActivityId(null); setDropTarget(null); }}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><circle cx="7" cy="5" r="1" />
                    <circle cx="13" cy="5" r="1" /><circle cx="7" cy="10" r="1" /><circle cx="13" cy="10" r="1" />
                    <circle cx="7" cy="15" r="1" /><circle cx="13" cy="15" r="1" /></svg>
                </button>}
                {canEdit && (row.kind === "stage" || row.kind === "discipline") &&
                  <button type="button" className="workspace-icon-action workspace-icon-action--move"
                    draggable={!moveBusy} disabled={moveBusy}
                    aria-label={messages.hierarchyMoveHandle(row.kind, row.label)}
                    title={messages.hierarchyMoveHandle(row.kind, row.label)}
                    onClick={(event) => { event.stopPropagation(); openStructureMoveDialog(row, event.currentTarget); }}
                    onDragStart={(event) => startStructureDrag(event, row)}
                    onDragEnd={() => { setDraggedStructureItem(null); setDropTarget(null); }}>
                    <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><circle cx="7" cy="5" r="1" />
                      <circle cx="13" cy="5" r="1" /><circle cx="7" cy="10" r="1" /><circle cx="13" cy="10" r="1" />
                      <circle cx="7" cy="15" r="1" /><circle cx="13" cy="15" r="1" /></svg>
                  </button>}
                {canEdit && row.kind === "product" && onAddRootActivity && <button type="button" className="workspace-icon-action"
                  aria-label={messages.addActivity} title={messages.addActivity}
                  onClick={() => { setSelected(row.key); onAddRootActivity(); }}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="M10 3v14M3 10h14" /></svg>
                </button>}
                {canEdit && row.kind !== "product" && <button type="button" className="workspace-icon-action"
                  aria-label={row.kind === "discipline" ? messages.editDiscipline : row.kind === "stage" ? messages.editStage : messages.editActivity}
                  title={row.kind === "discipline" ? messages.editDiscipline : row.kind === "stage" ? messages.editStage : messages.editActivity}
                  onClick={() => { setSelected(row.key); onEdit(row); }}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="m13.8 3.2 3 3-9.9 9.9-3.6.7.7-3.6 9.8-10Z" /><path d="m11.9 5.1 3 3M3.5 16.5l3.6-.7" /></svg>
                </button>}
                {canEdit && (row.kind === "discipline" || row.kind === "stage") && <button type="button" className="workspace-icon-action"
                  aria-label={row.kind === "discipline" ? messages.addStage : messages.addActivity}
                  title={row.kind === "discipline" ? messages.addStage : messages.addActivity}
                  onClick={() => { setSelected(row.key); onAdd(row); }}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="M10 3v14M3 10h14" /></svg>
                </button>}
                {canEdit && row.kind !== "product" && <button type="button" className="workspace-icon-action workspace-icon-action--delete"
                  aria-label={`${messages.deleteScheduleItem(row.kind)}: ${row.label}`}
                  title={`${messages.deleteScheduleItem(row.kind)}: ${row.label}`}
                  onClick={(event) => { setSelected(row.key); startDeletion(row, event.currentTarget); }}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="M4 6h12m-10 0 .7 10h6.6L14 6M8 6V4h4v2m-3 3v4m2-4v4" /></svg>
                </button>}
                {row.kind === "activity" && <button type="button" className="workspace-icon-action"
                  title={messages.activityDateHistoryFor(row.label)} onClick={() => { setSelected(row.key); onHistory(row); }}
                  aria-label={messages.activityDateHistoryFor(row.label)}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="M3 4.5h14v12H3zM6 2.5v4M14 2.5v4M3 8h14M6 11h2m2 0h2m-6 3h2" /></svg>
                </button>}
              </span>
              <button type="button" className="workspace-row-name" title={row.label}
                onClick={() => setSelected(row.key)}
                onDoubleClick={() => { if (canEdit) { setSelected(row.key); onEdit(row); } }}>
                {row.label}{row.code ? ` (${row.code})` : ""}
              </button>
              {draggedActivityId && row.kind === "product" && <span className="workspace-drop-hint">{messages.activityMoveRootTarget}</span>}
              {draggedActivityId && row.kind === "stage" && <span className="workspace-drop-hint">{messages.activityMoveStageTarget}</span>}
              {draggedStructureItem?.kind === "stage" && row.kind === "discipline" &&
                <span className="workspace-drop-hint">{messages.stageMoveDisciplineTarget}</span>}
              {draggedStructureItem?.kind === "discipline" && row.kind === "discipline" && row.id !== draggedStructureItem.id &&
                <span className="workspace-drop-hint">{messages.disciplineMoveTarget}</span>}
            </div>
            <span role="cell" className="workspace-date-cell" onDoubleClick={() => {
              if (canEdit) { setSelected(row.key); onEdit(row); }
            }}>{formatCivilDate(row.start)}</span>
            <span role="cell" className="workspace-date-cell" onDoubleClick={() => {
              if (canEdit) { setSelected(row.key); onEdit(row); }
            }}>{formatCivilDate(row.end)}</span>
          </div>;
          })}
        </div>
        <div className="workspace-divider" role="separator" tabIndex={0} aria-orientation="vertical"
          aria-label={messages.resizeSchedulePanes} aria-valuemin={30} aria-valuemax={70} aria-valuenow={tableWidth}
          onPointerDown={() => { dragging.current = true; }} onKeyDown={(event) => {
            if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
              event.preventDefault();
              setTableWidth((value) => Math.min(70, Math.max(30, value + (event.key === "ArrowRight" ? 5 : -5))));
            }
          }} />
        <div ref={chartRef} className="workspace-chart-scroll" onScroll={() => syncScroll("chart")}
          onClick={(event) => { if (!(event.target as Element).closest(".timeline-bar")) selectDate(event); }}
          aria-label={messages.scheduleGantt}>
          <div className="workspace-chart-content" style={{ width: scale.width, backgroundSize: `${scale.dayWidth}px 100%` }}>
            <div className="timeline-nonworking-days" aria-hidden="true">
              {nonWorkingRanges.map((range) => <span key={`${range.startDay}:${range.dayCount}`}
                data-start-date={civilFromDay(range.startDay)}
                data-end-date={civilFromDay(range.startDay + range.dayCount - 1)}
                style={{ left: (range.startDay - scale.startDay) * scale.dayWidth, width: range.dayCount * scale.dayWidth }} />)}
            </div>
            {selectedDate && <div className="timeline-selected-column" data-date={selectedDate}
              style={{ left: timelinePosition(scale, selectedDate), width: scale.dayWidth }} />}
            {targets.map((target) => <button type="button" key={target.id} className="timeline-target-line"
              style={{ left: timelinePosition(scale, target.targetDate), borderColor: target.color }}
              title={messages.targetDetail(target.name, formatCivilDate(target.targetDate))}
              aria-label={`${messages.targetDetail(target.name, formatCivilDate(target.targetDate))}. ${canEdit ? messages.edit : messages.milestoneView}`}
              onClick={(event) => { event.stopPropagation(); setTargetDialog(target); }} />)}
            <div className="timeline-today-line" data-date={today}
              style={{ left: timelinePosition(scale, today) }}
              title={`${messages.today}: ${formatCivilDate(today)}`} />
            {rows.map((row) => {
              const interval = timelineInterval(scale, row.start, row.end);
              const impact = row.kind === "activity" ? impactByActivity.get(row.id) : undefined;
              const proposedInterval = impact
                ? timelineInterval(scale, impact.proposedStartDate, impact.proposedEndDate) : null;
              return <div key={row.key} className={`workspace-chart-row row-${row.kind}${selected === row.key ? " selected" : ""}${hoveredRowKey === row.key ? " is-hovered" : ""}`}
                data-row-key={row.key}
                onMouseEnter={() => enterRow(row.key)} onMouseLeave={() => leaveRow(row.key)}
                onClick={() => setSelected(row.key)}>
                {interval && <button type="button" className={`timeline-bar bar-${row.kind}`}
                  style={{ left: interval.left, width: interval.width, backgroundColor: row.color ?? "var(--jl-gantt-line-fallback)" }}
                  title={messages.scheduleBarDetail(row.label, formatCivilDate(row.start), formatCivilDate(row.end))}
                  aria-label={messages.scheduleBarDetail(row.label, formatCivilDate(row.start), formatCivilDate(row.end))}
                  onClick={() => setSelected(row.key)} />}
                {proposedInterval && <span className="timeline-proposed-bar" data-activity-id={row.id}
                  aria-hidden="true" style={{ left: proposedInterval.left, width: proposedInterval.width }} />}
                {!interval && row.kind === "stage" && <span className="workspace-no-date">{messages.noActivities}</span>}
              </div>;
            })}
          </div>
        </div>
      </div>
      <div className="workspace-scrollbar-row" aria-label={messages.scheduleTimeline}>
        <div className="workspace-scrollbar-spacer" />
        <div className="workspace-divider-footer" />
        <div ref={scrollbarRef} className="workspace-horizontal-scroll" onScroll={() => syncScroll("scrollbar")}
          role="region" tabIndex={0} aria-label={messages.scheduleTimeline}>
          <div className="workspace-horizontal-content" style={{ width: scale.width }} />
        </div>
      </div>
    </div>
    {targetDialog && <TargetDialog target={targetDialog === "new" ? null : targetDialog}
      initialDate={selectedDate ?? today} canEdit={canEdit} userId={userId}
      onClose={() => setTargetDialog(null)} onCreate={onCreateTarget} onUpdate={onUpdateTarget}
      onDelete={onDeleteTarget} />}
    {moveDialog && <div className="activity-move-backdrop" onMouseDown={(event) => {
      if (event.target === event.currentTarget && !moveBusy) closeMoveDialog();
    }}>
      <div ref={moveDialogElement} className="activity-move-dialog" role="dialog" aria-modal="true"
        aria-labelledby="activity-move-title" aria-describedby="activity-move-description">
        <h2 id="activity-move-title">{messages.activityMoveDialogTitle}</h2>
        <p className="activity-move-dialog__target">{moveDialog.label}</p>
        <p id="activity-move-description">{messages.activityMoveDialogDescription}</p>
        <form onSubmit={submitActivityMoveDialog}>
          <label htmlFor="activity-move-destination">{messages.activityMoveDestination}</label>
          <select id="activity-move-destination" value={moveDialog.destinationStageId ?? "root"} disabled={moveBusy}
            onChange={(event) => setMoveDialog((current) => current ? { ...current,
              destinationStageId: event.target.value === "root" ? null : event.target.value } : null)}>
            <option value="root">{messages.activityMoveProductRoot}</option>
            {tree.disciplines.flatMap((discipline) => discipline.stages.map((stage) =>
              <option key={stage.id} value={stage.id}>{discipline.name} — {stage.displayName}</option>))}
          </select>
          <label htmlFor="activity-move-position">{messages.activityMovePosition}</label>
          <select id="activity-move-position" value={moveDialog.position} disabled={moveBusy}
            onChange={(event) => setMoveDialog((current) => current ? { ...current,
              position: event.target.value as "start" | "end" } : null)}>
            <option value="start">{messages.activityMoveStart}</option>
            <option value="end">{messages.activityMoveEnd}</option>
          </select>
          {moveBusy && <p role="status">{messages.activityMoveSubmitting}</p>}
          <div className="activity-move-dialog__actions">
            <button type="button" disabled={moveBusy} onClick={closeMoveDialog}>{messages.cancel}</button>
            <button type="submit" disabled={moveBusy}>{moveBusy ? messages.activityMoveSubmitting : messages.activityMoveConfirm}</button>
          </div>
        </form>
      </div>
    </div>}
    {structureMoveDialog && <div className="activity-move-backdrop" onMouseDown={(event) => {
      if (event.target === event.currentTarget && !moveBusy) closeMoveDialog();
    }}>
      <div ref={moveDialogElement} className="activity-move-dialog" role="dialog" aria-modal="true"
        aria-labelledby="hierarchy-move-title" aria-describedby="hierarchy-move-description">
        <h2 id="hierarchy-move-title">{messages.hierarchyMoveDialogTitle(structureMoveDialog.kind)}</h2>
        <p className="activity-move-dialog__target">{structureMoveDialog.label}</p>
        <p id="hierarchy-move-description">{messages.hierarchyMoveDialogDescription(structureMoveDialog.kind)}</p>
        <form onSubmit={submitStructureMoveDialog}>
          {structureMoveDialog.kind === "stage" && <>
            <label htmlFor="hierarchy-move-destination">{messages.hierarchyMoveDestination}</label>
            <select id="hierarchy-move-destination" value={structureMoveDialog.destinationDisciplineId ?? ""}
              disabled={moveBusy} onChange={(event) => setStructureMoveDialog((current) => current ? {
                ...current, destinationDisciplineId: event.target.value || null
              } : null)}>
              <option value="">{messages.hierarchyMoveChooseDiscipline}</option>
              {tree.disciplines.map((discipline) => <option key={discipline.id} value={discipline.id}>{discipline.name}</option>)}
            </select>
          </>}
          <label htmlFor="hierarchy-move-position">{messages.activityMovePosition}</label>
          <select id="hierarchy-move-position" value={structureMoveDialog.position} disabled={moveBusy}
            onChange={(event) => setStructureMoveDialog((current) => current ? {
              ...current, position: event.target.value as "start" | "end"
            } : null)}>
            <option value="start">{messages.activityMoveStart}</option>
            <option value="end">{messages.activityMoveEnd}</option>
          </select>
          {moveBusy && <p role="status">{messages.hierarchyMoveSubmitting(structureMoveDialog.kind)}</p>}
          <div className="activity-move-dialog__actions">
            <button type="button" disabled={moveBusy} onClick={closeMoveDialog}>{messages.cancel}</button>
            <button type="submit" disabled={moveBusy || (structureMoveDialog.kind === "stage" && !structureMoveDialog.destinationDisciplineId)}>
              {moveBusy ? messages.hierarchyMoveSubmitting(structureMoveDialog.kind) : messages.hierarchyMoveConfirm(structureMoveDialog.kind)}
            </button>
          </div>
        </form>
      </div>
    </div>}
    {deletionTarget && <div className="schedule-deletion-backdrop" onMouseDown={(event) => {
      if (event.target === event.currentTarget && !deletionBusy) {
        deletionRequest.current++;
        setDeletionTarget(null);
        setDeletionPreview(null);
        queueMicrotask(() => deletionTrigger.current?.focus());
      }
    }}>
      <div ref={deletionDialog} className="schedule-deletion-dialog" role="alertdialog" aria-modal="true"
        aria-labelledby="schedule-deletion-title" aria-describedby="schedule-deletion-explanation">
        <h2 id="schedule-deletion-title">{messages.confirmScheduleDeletion}</h2>
        <p className="schedule-deletion-dialog__target">{messages.scheduleDeletionTarget(deletionTarget.kind, deletionTarget.label)}</p>
        <p id="schedule-deletion-explanation">{messages.scheduleDeletionExplanation}</p>
        {deletionLoading ? <p role="status">{messages.scheduleDeletionPreviewLoading}</p> : deletionPreview &&
          <p className="schedule-deletion-dialog__impact" aria-live="polite">{messages.scheduleDeletionImpact(
            deletionPreview.counts.disciplines, deletionPreview.counts.stages, deletionPreview.counts.activities)}</p>}
        {deletionError && <p role="alert" className="schedule-deletion-dialog__error">{deletionError}</p>}
        {deletionStale && <button type="button" disabled={deletionBusy} onClick={() =>
          void fetchDeletionPreview(deletionTarget, false)}>{messages.scheduleDeletionRefreshPreview}</button>}
        <form onSubmit={(event) => void confirmDeletion(event)}>
          <label htmlFor="schedule-deletion-reason">{messages.scheduleDeletionReason}</label>
          <textarea id="schedule-deletion-reason" maxLength={2000} required minLength={10}
            value={deletionReason} disabled={deletionBusy || !deletionPreview || deletionLoading}
            aria-describedby="schedule-deletion-reason-hint"
            onChange={(event) => { setDeletionReason(event.target.value); setDeletionError(""); }} />
          <small id="schedule-deletion-reason-hint">{messages.scheduleDeletionReasonHint}</small>
          <div className="schedule-deletion-dialog__actions">
            <button type="button" disabled={deletionBusy} onClick={() => {
              deletionRequest.current++;
              setDeletionTarget(null);
              setDeletionPreview(null);
              queueMicrotask(() => deletionTrigger.current?.focus());
            }}>{messages.scheduleDeletionCancel}</button>
            <button type="submit" disabled={deletionBusy || deletionLoading || !deletionPreview ||
              deletionStale || deletionReason.trim().length < 10}>
              {deletionBusy ? messages.scheduleDeletionSubmitting : messages.scheduleDeletionConfirm}
            </button>
          </div>
        </form>
      </div>
    </div>}
  </section>;
}

function TargetDialog({ target, initialDate, canEdit, userId, onClose, onCreate, onUpdate, onDelete }: {
  target: ScheduleTarget | null; initialDate: string; canEdit: boolean; userId?: string | null; onClose: () => void;
  onCreate: (value: { name: string; description: string | null; targetDate: string; color: string }) => Promise<ScheduleTarget>;
  onUpdate: (target: ScheduleTarget, value: { name: string; description: string | null;
    targetDate: string; color: string; reason: string | null }) => Promise<ScheduleTarget>;
  onDelete: (target: ScheduleTarget) => Promise<void>;
}) {
  const [name, setName] = useState(target?.name ?? "");
  const [description, setDescription] = useState(target?.description ?? "");
  const [date, setDate] = useState(formatCivilDate(target?.targetDate ?? initialDate));
  const [color, setColor] = useState(target?.color ?? "#AA4557");
  const [colorSelected, setColorSelected] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const dateChanged = !!target && parseBrazilianDate(date) !== target.targetDate;
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!name.trim()) { setError(messages.milestoneNameRequired); return; }
    const iso = parseBrazilianDate(date);
    if (!iso) { setError(messages.milestoneDateInvalid); return; }
    if (dateChanged && reason.trim().length < 10) { setError(messages.milestoneReasonRequired); return; }
    setBusy(true); setError("");
    try {
      const value = { name: name.trim(), description: description.trim() || null, targetDate: iso, color };
      if (target) await onUpdate(target, { ...value, reason: dateChanged ? reason.trim() : null });
      else await onCreate(value);
      if (colorSelected) rememberRecentCustomColor(userId, color);
      onClose();
    } catch (cause) { setError(cause instanceof Error ? cause.message : messages.milestoneSaveError); }
    finally { setBusy(false); }
  }
  async function remove() {
    if (!target || !window.confirm(messages.milestoneDeleteConfirm(target.name))) return;
    setBusy(true); setError("");
    try { await onDelete(target); onClose(); }
    catch (cause) { setError(cause instanceof Error ? cause.message : messages.milestoneDeleteError); }
    finally { setBusy(false); }
  }
  return <div className="schedule-drawer-backdrop" onMouseDown={(event) => {
    if (event.target === event.currentTarget && !busy) onClose();
  }}><form className="milestone-dialog" role="dialog" aria-modal="true"
    aria-labelledby="milestone-dialog-title" onSubmit={(event) => void save(event)}>
    <h3 id="milestone-dialog-title">{target ? (canEdit ? messages.milestoneEdit : messages.milestoneView) : messages.milestoneCreate}</h3>
    <label htmlFor="milestone-name">{messages.milestoneName}</label>
    <input id="milestone-name" aria-required="true" maxLength={200} value={name} disabled={!canEdit || busy}
      onChange={(event) => setName(event.target.value)} />
    <label htmlFor="milestone-description">{messages.milestoneDescription}</label>
    <textarea id="milestone-description" maxLength={2000} value={description} disabled={!canEdit || busy}
      onChange={(event) => setDescription(event.target.value)} />
    <label htmlFor="milestone-date">{messages.milestoneDate}</label>
    <DatePickerField id="milestone-date" label={messages.milestoneDate} ariaRequired
      value={date} disabled={!canEdit || busy} onChange={setDate} />
    <ColorField id="milestone-color" label={messages.milestoneColor} value={color} userId={userId}
      disabled={!canEdit || busy} onChange={(value) => { setColor(value); setColorSelected(true); }} />
    {dateChanged && canEdit && <>
      <label htmlFor="milestone-reason">{messages.milestoneReason}</label>
      <textarea id="milestone-reason" maxLength={2000} aria-required="true" value={reason}
        aria-describedby="milestone-reason-hint" disabled={busy}
        onChange={(event) => setReason(event.target.value)} />
      <small id="milestone-reason-hint">{messages.milestoneReasonHint}</small>
    </>}
    {error && <p role="alert">{error}</p>}
    <div className="milestone-actions">
      {canEdit && <button type="submit" disabled={busy}>{messages.milestoneSave}</button>}
      {target && canEdit && <button type="button" disabled={busy} onClick={() => void remove()}>{messages.milestoneDelete}</button>}
      <button type="button" disabled={busy} onClick={onClose}>{target && !canEdit ? messages.milestoneClose : messages.milestoneCancel}</button>
    </div>
  </form></div>;
}
