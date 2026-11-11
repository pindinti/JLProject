import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ScheduleEditor } from "../src/ScheduleEditor";
import { formatCivilDate, parseBrazilianDate } from "../src/civil-date";
import type { ActivityCalendarImpact } from "../domain/calendar-impact";
import { readRecentCustomColors } from "../src/recent-color-history";

const api = vi.hoisted(() => ({ fetch: vi.fn() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: api.fetch }));

const workspace = { id: "e97c159e-3f7b-4e27-8b1e-38036bf47a3f", name: "JLProject", role: "admin" as const };
const userId = "synthetic-user";
const product = { id: "e3aa998a-a2c3-4376-9105-90af0d1dbfe3", name: "Synthetic product", active: true };
const activity = { id: "cd960302-0b68-4621-95ed-7d4f57f8eedc", stageId: "7130dfdf-452d-4bfc-8ad0-9cbf4db53747",
  name: "Synthetic activity", activityType: null, plannedStart: "2026-11-01", plannedEnd: "2026-11-08",
  displayOrder: 0, notes: null, colorOverride: null, version: 1, planningMode: "manual" as const,
  workingDayDuration: null, planningCalendarVersion: null };
const stage = { id: activity.stageId, disciplineId: "bba53e18-f13f-4b2d-a02e-65a0d95627e6", code: "EC",
  color: "#336699", displayName: "Synthetic stage", displayOrder: 0, derivedStart: "2026-11-01",
  derivedEnd: "2026-11-08", version: 1, activities: [activity] };
const discipline = { id: stage.disciplineId, productId: product.id, name: "Synthetic discipline",
  shortCode: "ENG", color: "#225588", description: null, displayOrder: 0, version: 1, stages: [stage] };
const definitions = [{ id: "add2b76e-72b5-4a0a-b8e8-3bd095688a01", code: "EC", color: "#336699" }];
const workingActivity = { ...activity, plannedStart: "2026-11-09", plannedEnd: "2026-11-10",
  version: 3, planningMode: "working_days" as const, workingDayDuration: 2, planningCalendarVersion: 1 };
const workingTree = { productId: product.id, disciplines: [{ ...discipline, stages: [{ ...stage,
  derivedStart: "2026-11-09", derivedEnd: "2026-11-10", activities: [workingActivity] }] }] };
const rootActivity = { ...activity, id: "7e1a1a51-e9ef-4d70-8f57-4e12f045ab6f", stageId: null,
  name: "Synthetic root activity", plannedStart: "2026-11-11", plannedEnd: "2026-11-13",
  colorOverride: "#AA5577", version: 4 };
const rootTree = { productId: product.id, disciplines: [discipline], rootActivities: [rootActivity] };
const secondActivity = { ...activity, id: "02eb3d51-f256-4b9a-b939-a44ec2149906", name: "Second activity",
  displayOrder: 1, version: 2 };
const emptyStage = { ...stage, id: "f419b025-91db-4f0d-9720-45732e88a9c2", code: "EP",
  displayName: "Empty stage", displayOrder: 1, derivedStart: null, derivedEnd: null, activities: [] };
const moveTree = { productId: product.id, rootActivities: [rootActivity], disciplines: [{ ...discipline,
  stages: [{ ...stage, activities: [activity, secondActivity] }, emptyStage] }] };
const destinationDiscipline = { ...discipline, id: "c4ed7846-d610-4b96-b146-6dc58b19a27e",
  name: "Empty destination", shortCode: "OPS", displayOrder: 1, version: 5, stages: [] };
const dateImpact: ActivityCalendarImpact = { activityId: activity.id, disciplineId: discipline.id,
  stageId: stage.id, activityVersion: 3, workingDays: 2, savedCalendarVersion: 1,
  currentCalendarVersion: 2, currentStartDate: "2026-11-09", currentEndDate: "2026-11-10",
  proposedStartDate: "2026-11-09", proposedEndDate: "2026-11-11", impact: "date_change",
  skippedDates: [{ date: "2026-11-10", reasons: [{ kind: "national_holiday", code: "test" }] }],
  optionalDaysVerified: false, unverifiedOptionalYears: [2026] };

function json(value: unknown, status = 200) { return new Response(JSON.stringify(value), { status }); }
type EditorTree = { productId: string; disciplines: unknown[]; rootActivities?: unknown[] };
function setup(tree: EditorTree = { productId: product.id, disciplines: [discipline] },
  targets: unknown[] = []) {
  api.fetch.mockImplementation((path: string) => Promise.resolve(path.endsWith("/hierarchy")
    ? json({ hierarchy: tree }) : path.endsWith("/targets")
      ? json({ targets }) : path.includes("/change-history")
        ? json({ events: [], nextCursor: null }) : path.endsWith("/calendar-impact")
          ? json({ calendarVersion: 0, impacts: [] }) : path.includes("/calendar?year=")
            ? json({ calendar: { version: 0, exceptions: [] } }) : path.includes("/deletion-preview")
              ? json({ fingerprint: "a".repeat(32), counts: { disciplines: 0, stages: 0, activities: 1 } })
              : json({ stageDefinitions: definitions })));
}
function mount(role: "admin" | "editor" | "viewer" = "admin", onSummaryRefresh?: () => Promise<void>) {
  const onAccessLost = vi.fn();
  render(<ScheduleEditor workspace={{ ...workspace, role }} product={product} userId={userId}
    onBack={vi.fn()} onAccessLost={onAccessLost} onSummaryRefresh={onSummaryRefresh} />);
  return onAccessLost;
}

beforeEach(() => { vi.clearAllMocks(); localStorage.clear(); setup(); });

function setupImpacts(impacts: ActivityCalendarImpact[], tree: EditorTree = workingTree) {
  setup(tree);
  const fallback = api.fetch.getMockImplementation()!;
  api.fetch.mockImplementation((path: string, options?: RequestInit) => path.endsWith("/calendar-impact")
    ? Promise.resolve(json({ calendarVersion: 2, impacts })) : fallback(path, options));
}

describe("schedule editor", () => {
  it("requires a fresh server preview and reason, then reloads only after deletion succeeds", async () => {
    let resolveDeletion: ((response: Response) => void) | undefined;
    const summaryRefresh = vi.fn(async () => undefined);
    api.fetch.mockImplementation((path: string) => {
      if (path.endsWith("/hierarchy/deletions"))
        return new Promise<Response>((resolve) => { resolveDeletion = resolve; });
      if (path.includes("/deletion-preview")) return Promise.resolve(json({ fingerprint: "b".repeat(32),
        counts: { disciplines: 0, stages: 0, activities: 1 } }));
      if (path.endsWith("/hierarchy")) return Promise.resolve(json({ hierarchy: { productId: product.id, disciplines: [discipline] } }));
      if (path.endsWith("/targets")) return Promise.resolve(json({ targets: [] }));
      if (path.endsWith("/calendar-impact")) return Promise.resolve(json({ calendarVersion: 0, impacts: [] }));
      if (path.includes("/calendar?year=")) return Promise.resolve(json({ calendar: { version: 0, exceptions: [] } }));
      return Promise.resolve(json({ stageDefinitions: definitions }));
    });
    mount("editor", summaryRefresh);
    fireEvent.click(await screen.findByRole("button", { name: "Excluir atividade: Synthetic activity" }));
    const dialog = await screen.findByRole("alertdialog", { name: "Confirmar exclusão do cronograma" });
    expect(within(dialog).getByText("Atividade: Synthetic activity")).toBeInTheDocument();
    expect(within(dialog).getByText(/0 disciplinas, 0 etapas e 1 atividade/)).toBeInTheDocument();
    expect(within(dialog).getByText(/histórico e a revisão R00 serão preservados/)).toBeInTheDocument();
    expect(api.fetch.mock.calls.some(([path]) => String(path).includes("/deletion-preview?kind=activity"))).toBe(true);
    const submit = within(dialog).getByRole("button", { name: "Excluir do cronograma" });
    expect(submit).toBeDisabled();
    fireEvent.change(within(dialog).getByLabelText("Justificativa da exclusão"), { target: { value: "Curta" } });
    expect(submit).toBeDisabled();
    fireEvent.change(within(dialog).getByLabelText("Justificativa da exclusão"), {
      target: { value: "Remoção sintética para validar o fluxo" }
    });
    fireEvent.click(submit);
    await waitFor(() => expect(api.fetch.mock.calls.some(([path]) => String(path).endsWith("/hierarchy/deletions"))).toBe(true));
    const deletionCall = api.fetch.mock.calls.find(([path]) => String(path).endsWith("/hierarchy/deletions"))!;
    expect(JSON.parse(deletionCall[1]?.body as string)).toEqual({ kind: "activity",
      targetId: activity.id, fingerprint: "b".repeat(32), reason: "Remoção sintética para validar o fluxo" });
    expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy"))).toHaveLength(1);
    expect(summaryRefresh).not.toHaveBeenCalled();
    const impactReadsBeforeSuccess = api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/calendar-impact")).length;
    await act(async () => { resolveDeletion?.(json({ operationId: "synthetic-operation", counts: { disciplines: 0, stages: 0, activities: 1 } })); });
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy"))).toHaveLength(2));
    expect(summaryRefresh).toHaveBeenCalledOnce();
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/calendar-impact")).length)
      .toBe(impactReadsBeforeSuccess + 1));
  });

  it("hides deletion controls from viewers", async () => {
    mount("viewer");
    await screen.findByText("Synthetic activity");
    expect(screen.queryByRole("button", { name: /Excluir atividade/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Mover atividade:/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Mover etapa:/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Mover disciplina:/ })).not.toBeInTheDocument();
  });

  it.each(["admin", "editor"] as const)("shows the activity move control to %s members", async (role) => {
    const { unmount } = render(<ScheduleEditor workspace={{ ...workspace, role }} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    expect(screen.getByRole("button", { name: /Mover atividade: Synthetic activity/ })).toBeEnabled();
    unmount();
  });

  it("shows an insertion indicator and keeps the loaded order until the server confirms and refreshes", async () => {
    let currentTree: EditorTree = moveTree;
    let resolveMove: ((response: Response) => void) | undefined;
    api.fetch.mockImplementation((path: string) => path.endsWith("/hierarchy")
      ? Promise.resolve(json({ hierarchy: currentTree })) : path.endsWith("/targets")
        ? Promise.resolve(json({ targets: [] })) : path.endsWith("/hierarchy/moves")
          ? new Promise<Response>((resolve) => { resolveMove = resolve; })
          : path.endsWith("/calendar-impact") ? Promise.resolve(json({ calendarVersion: 0, impacts: [] }))
            : path.includes("/calendar?year=") ? Promise.resolve(json({ calendar: { version: 0, exceptions: [] } }))
              : Promise.resolve(json({ stageDefinitions: definitions })));
    render(<ScheduleEditor workspace={{ ...workspace, role: "editor" }} product={product} userId={userId}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    const secondRow = await screen.findByText("Second activity").then((name) => name.closest(".workspace-table-row")!);
    const firstRow = screen.getByText("Synthetic activity").closest(".workspace-table-row")!;
    const handle = screen.getByRole("button", { name: "Mover atividade: Second activity. Arraste para reordenar ou use o teclado para escolher o destino." });
    expect(handle).toHaveAttribute("draggable", "true");
    fireEvent.dragStart(handle, { dataTransfer: { setData: vi.fn(), effectAllowed: "", dropEffect: "" } });
    fireEvent.dragOver(firstRow, { clientY: -1, dataTransfer: { dropEffect: "" } });
    expect(firstRow).toHaveClass("drop-before");
    expect(screen.getByText("Soltar antes de Synthetic activity.")).toBeInTheDocument();
    fireEvent.drop(firstRow, { clientY: -1, dataTransfer: { dropEffect: "" } });
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy/moves"))).toHaveLength(1));
    const call = api.fetch.mock.calls.find(([path]) => String(path).endsWith("/hierarchy/moves"))!;
    expect(JSON.parse(call[1]?.body as string)).toEqual({ kind: "activity", targetId: secondActivity.id,
      expectedVersion: secondActivity.version, destinationDisciplineId: discipline.id, destinationStageId: stage.id,
      destinationIndex: 0, expectedSourceOrder: [activity.id, secondActivity.id],
      expectedDestinationOrder: [activity.id, secondActivity.id] });
    expect(document.querySelectorAll(".workspace-table-row.row-activity")[1]).toHaveAttribute("data-row-key", `activity:${activity.id}`);

    currentTree = { ...moveTree, disciplines: [{ ...moveTree.disciplines[0]!, stages: [
      { ...moveTree.disciplines[0]!.stages[0]!, activities: [
        { ...secondActivity, displayOrder: 0 }, { ...activity, displayOrder: 1 }
      ] }, emptyStage
    ] }] };
    await act(async () => { resolveMove?.(json({ changed: true, operationId: "synthetic-move", version: 3 })); });
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy"))).toHaveLength(2));
    await waitFor(() => expect(document.querySelectorAll(".workspace-table-row.row-activity")[1])
      .toHaveAttribute("data-row-key", `activity:${secondActivity.id}`));
    expect(Array.from(document.querySelectorAll(".workspace-table-row")).map((row) => row.getAttribute("data-row-key")))
      .toEqual(Array.from(document.querySelectorAll(".workspace-chart-row")).map((row) => row.getAttribute("data-row-key")));
    expect(secondRow).toBeInTheDocument();
    expect(await screen.findByRole("status")).toHaveTextContent("Atividade movida. O cronograma foi atualizado.");
  });

  it("lets an editor use the keyboard move dialog to place an activity in an empty stage", async () => {
    setup(moveTree);
    const fallback = api.fetch.getMockImplementation()!;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => path.endsWith("/hierarchy/moves")
      ? Promise.resolve(json({ changed: true, operationId: "synthetic-move", version: 4 })) : fallback(path, options));
    mount("editor");
    await screen.findByText("Synthetic activity");
    fireEvent.click(screen.getByRole("button", { name: "Mover atividade: Synthetic activity. Arraste para reordenar ou use o teclado para escolher o destino." }));
    const dialog = screen.getByRole("dialog", { name: "Mover atividade" });
    fireEvent.change(within(dialog).getByLabelText("Destino"), { target: { value: emptyStage.id } });
    fireEvent.change(within(dialog).getByLabelText("Posição"), { target: { value: "start" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Mover atividade" }));
    await waitFor(() => expect(api.fetch.mock.calls.some(([path]) => String(path).endsWith("/hierarchy/moves"))).toBe(true));
    const call = api.fetch.mock.calls.find(([path]) => String(path).endsWith("/hierarchy/moves"))!;
    expect(JSON.parse(call[1]?.body as string)).toEqual({ kind: "activity", targetId: activity.id,
      expectedVersion: activity.version, destinationDisciplineId: discipline.id, destinationStageId: emptyStage.id,
      destinationIndex: 0, expectedSourceOrder: [activity.id, secondActivity.id], expectedDestinationOrder: [] });
  });

  it("shows the empty product root as a drop target and moves an activity there", async () => {
    setup({ productId: product.id, disciplines: [discipline] });
    const fallback = api.fetch.getMockImplementation()!;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => path.endsWith("/hierarchy/moves")
      ? Promise.resolve(json({ changed: true, operationId: "synthetic-root-move", version: 2 })) : fallback(path, options));
    const { container } = render(<ScheduleEditor workspace={{ ...workspace, role: "editor" }} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    const handle = screen.getByRole("button", { name: /Mover atividade: Synthetic activity/ });
    const productRow = container.querySelector<HTMLElement>(".workspace-table-row.row-product")!;
    fireEvent.dragStart(handle, { dataTransfer: { setData: vi.fn(), effectAllowed: "", dropEffect: "" } });
    fireEvent.dragOver(productRow, { clientY: 0, dataTransfer: { dropEffect: "" } });
    expect(productRow).toHaveClass("drop-append");
    expect(within(productRow).getByText("Solte aqui para colocar em Atividades de Produto")).toBeInTheDocument();
    expect(screen.getByText("Soltar no fim de Atividades de Produto.")).toBeInTheDocument();
    fireEvent.drop(productRow, { clientY: 0, dataTransfer: { dropEffect: "" } });
    await waitFor(() => expect(api.fetch.mock.calls.some(([path]) => String(path).endsWith("/hierarchy/moves"))).toBe(true));
    const call = api.fetch.mock.calls.find(([path]) => String(path).endsWith("/hierarchy/moves"))!;
    expect(JSON.parse(call[1]?.body as string)).toEqual({ kind: "activity", targetId: activity.id,
      expectedVersion: activity.version, destinationDisciplineId: null, destinationStageId: null,
      destinationIndex: 0, expectedSourceOrder: [activity.id], expectedDestinationOrder: [] });
  });

  it("rejects a drop on a discipline and prevents duplicate submissions while a move is pending", async () => {
    setup(moveTree);
    let resolveMove: ((response: Response) => void) | undefined;
    const fallback = api.fetch.getMockImplementation()!;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => path.endsWith("/hierarchy/moves")
      ? new Promise<Response>((resolve) => { resolveMove = resolve; }) : fallback(path, options));
    const { container } = render(<ScheduleEditor workspace={{ ...workspace, role: "editor" }} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    fireEvent.dragStart(screen.getByRole("button", { name: /Mover atividade: Second activity/ }),
      { dataTransfer: { setData: vi.fn(), effectAllowed: "", dropEffect: "" } });
    const disciplineRow = container.querySelector<HTMLElement>(".workspace-table-row.row-discipline")!;
    fireEvent.drop(disciplineRow, { dataTransfer: { dropEffect: "" } });
    expect(await screen.findByRole("alert")).toHaveTextContent("Escolha uma atividade e um destino válidos.");
    expect(api.fetch.mock.calls.some(([path]) => String(path).endsWith("/hierarchy/moves"))).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: /Mover atividade: Second activity/ }));
    const dialog = screen.getByRole("dialog", { name: "Mover atividade" });
    const form = dialog.querySelector("form")!;
    act(() => { fireEvent.submit(form); fireEvent.submit(form); });
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy/moves"))).toHaveLength(1));
    expect(within(dialog).getByRole("button", { name: "Movendo atividade…" })).toBeDisabled();
    await act(async () => { resolveMove?.(json({ changed: false, version: 2 })); });
    expect(await screen.findByRole("status")).toHaveTextContent("A atividade já está nessa posição.");
    expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy/moves"))).toHaveLength(1);
  });

  it("maps stale and denied moves to accessible feedback without optimistic changes", async () => {
    let moveStatus = 409;
    api.fetch.mockImplementation((path: string) => path.endsWith("/hierarchy/moves")
      ? Promise.resolve(json({ error: "move failed" }, moveStatus))
      : path.endsWith("/hierarchy") ? Promise.resolve(json({ hierarchy: moveTree }))
        : path.endsWith("/targets") ? Promise.resolve(json({ targets: [] }))
          : path.endsWith("/calendar-impact") ? Promise.resolve(json({ calendarVersion: 0, impacts: [] }))
            : path.includes("/calendar?year=") ? Promise.resolve(json({ calendar: { version: 0, exceptions: [] } }))
              : Promise.resolve(json({ stageDefinitions: definitions })));
    const onAccessLost = mount("editor");
    await screen.findByText("Synthetic activity");
    const handle = screen.getByRole("button", { name: /Mover atividade: Synthetic activity/ });
    fireEvent.click(handle);
    const dialog = screen.getByRole("dialog", { name: "Mover atividade" });
    fireEvent.click(within(dialog).getByRole("button", { name: "Mover atividade" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("A ordem do cronograma mudou. Atualize os dados e tente novamente.");
    expect(screen.getByRole("button", { name: "Synthetic activity" }).closest(".workspace-table-row")).toBeInTheDocument();
    moveStatus = 403;
    fireEvent.click(within(dialog).getByRole("button", { name: "Mover atividade" }));
    await waitFor(() => expect(onAccessLost).toHaveBeenCalled());
    expect(await screen.findByRole("alert")).toHaveTextContent("Você não tem permissão para mover esta atividade.");
  });

  it("reorders stages within their discipline using the stage version and full sibling order", async () => {
    setup(moveTree);
    const fallback = api.fetch.getMockImplementation()!;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => path.endsWith("/hierarchy/moves")
      ? Promise.resolve(json({ changed: true, operationId: "synthetic-stage-reorder", version: 4 })) : fallback(path, options));
    const { container } = render(<ScheduleEditor workspace={{ ...workspace, role: "editor" }} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    const firstRow = container.querySelector<HTMLElement>(`[data-row-key="stage:${stage.id}"]`)!;
    const secondRow = container.querySelector<HTMLElement>(`[data-row-key="stage:${emptyStage.id}"]`)!;
    fireEvent.dragStart(within(secondRow).getByRole("button", { name: /Mover etapa: Empty stage/ }),
      { dataTransfer: { setData: vi.fn(), effectAllowed: "", dropEffect: "" } });
    fireEvent.dragOver(firstRow, { clientY: -1, dataTransfer: { dropEffect: "" } });
    expect(firstRow).toHaveClass("drop-before");
    fireEvent.drop(firstRow, { clientY: -1, dataTransfer: { dropEffect: "" } });
    await waitFor(() => expect(api.fetch.mock.calls.some(([path]) => String(path).endsWith("/hierarchy/moves"))).toBe(true));
    const moveCall = api.fetch.mock.calls.find(([path]) => String(path).endsWith("/hierarchy/moves"))!;
    expect(JSON.parse(moveCall[1]?.body as string)).toEqual({ kind: "stage", targetId: emptyStage.id,
      expectedVersion: emptyStage.version, destinationDisciplineId: discipline.id, destinationStageId: null,
      destinationIndex: 0, expectedSourceOrder: [stage.id, emptyStage.id],
      expectedDestinationOrder: [stage.id, emptyStage.id] });
    expect(Array.from(container.querySelectorAll(".workspace-table-row.row-stage")).map((row) => row.getAttribute("data-row-key")))
      .toEqual([`stage:${stage.id}`, `stage:${emptyStage.id}`]);
  });

  it("moves a stage with descendants to an empty discipline only after confirmation", async () => {
    const preservedActivity = { ...activity, colorOverride: "#AA5577" };
    let currentTree: EditorTree = { productId: product.id, disciplines: [
      { ...discipline, stages: [{ ...stage, activities: [preservedActivity] }, emptyStage] }, destinationDiscipline
    ] };
    let resolveMove: ((response: Response) => void) | undefined;
    api.fetch.mockImplementation((path: string) => path.endsWith("/hierarchy")
      ? Promise.resolve(json({ hierarchy: currentTree })) : path.endsWith("/hierarchy/moves")
        ? new Promise<Response>((resolve) => { resolveMove = resolve; }) : path.endsWith("/targets")
          ? Promise.resolve(json({ targets: [] })) : path.endsWith("/calendar-impact")
            ? Promise.resolve(json({ calendarVersion: 0, impacts: [] })) : path.includes("/calendar?year=")
              ? Promise.resolve(json({ calendar: { version: 0, exceptions: [] } }))
              : Promise.resolve(json({ stageDefinitions: definitions })));
    const { container } = render(<ScheduleEditor workspace={{ ...workspace, role: "editor" }} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    const sourceRow = container.querySelector<HTMLElement>(`[data-row-key="stage:${stage.id}"]`)!;
    const destinationRow = container.querySelector<HTMLElement>(`[data-row-key="discipline:${destinationDiscipline.id}"]`)!;
    const handle = within(sourceRow).getByRole("button", { name: /Mover etapa: Synthetic stage/ });
    fireEvent.dragStart(handle, { dataTransfer: { setData: vi.fn(), effectAllowed: "", dropEffect: "" } });
    fireEvent.dragOver(destinationRow, { clientY: 0, dataTransfer: { dropEffect: "" } });
    expect(destinationRow).toHaveClass("drop-append");
    expect(within(destinationRow).getByText("Solte aqui para mover a etapa para esta disciplina")).toBeInTheDocument();
    fireEvent.drop(destinationRow, { clientY: 0, dataTransfer: { dropEffect: "" } });
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy/moves"))).toHaveLength(1));
    const moveCall = api.fetch.mock.calls.find(([path]) => String(path).endsWith("/hierarchy/moves"))!;
    expect(JSON.parse(moveCall[1]?.body as string)).toEqual({ kind: "stage", targetId: stage.id,
      expectedVersion: stage.version, destinationDisciplineId: destinationDiscipline.id, destinationStageId: null,
      destinationIndex: 0, expectedSourceOrder: [stage.id, emptyStage.id], expectedDestinationOrder: [] });
    expect(container.querySelector(`[data-row-key="stage:${stage.id}"]`)).toBeInTheDocument();
    expect(container.querySelector(`[data-row-key="activity:${activity.id}"]`)).toBeInTheDocument();
    expect(Array.from(container.querySelectorAll(".workspace-table-row")).map((row) => row.getAttribute("data-row-key")))
      .toEqual(Array.from(container.querySelectorAll(".workspace-chart-row")).map((row) => row.getAttribute("data-row-key")));

    currentTree = { productId: product.id, disciplines: [
      { ...discipline, stages: [emptyStage] },
      { ...destinationDiscipline, stages: [{ ...stage, disciplineId: destinationDiscipline.id, activities: [preservedActivity] }] }
    ] };
    await act(async () => { resolveMove?.(json({ changed: true, operationId: "synthetic-stage-move", version: 3 })); });
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy"))).toHaveLength(2));
    expect(container.querySelector(`[data-row-key="activity:${activity.id}"]`)).toBeInTheDocument();
    expect(container.querySelector(`.workspace-chart-row[data-row-key="activity:${activity.id}"] .timeline-bar`))
      .toHaveStyle({ backgroundColor: "rgb(170, 85, 119)" });
    expect(Array.from(container.querySelectorAll(".workspace-table-row")).map((row) => row.getAttribute("data-row-key")))
      .toEqual(Array.from(container.querySelectorAll(".workspace-chart-row")).map((row) => row.getAttribute("data-row-key")));
  });

  it("supports keyboard stage moves and discipline reordering with versioned order metadata", async () => {
    const tree = { productId: product.id, disciplines: [
      { ...discipline, stages: [{ ...stage, activities: [activity, secondActivity] }, emptyStage] }, destinationDiscipline
    ] };
    setup(tree);
    const fallback = api.fetch.getMockImplementation()!;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => path.endsWith("/hierarchy/moves")
      ? Promise.resolve(json({ changed: true, operationId: "synthetic-move", version: 4 })) : fallback(path, options));
    mount("admin");
    await screen.findByText("Synthetic activity");
    fireEvent.click(screen.getByRole("button", { name: /Mover etapa: Empty stage/ }));
    const stageDialog = screen.getByRole("dialog", { name: "Mover etapa" });
    fireEvent.change(within(stageDialog).getByLabelText("Disciplina de destino"), { target: { value: destinationDiscipline.id } });
    fireEvent.change(within(stageDialog).getByLabelText("Posição"), { target: { value: "start" } });
    fireEvent.click(within(stageDialog).getByRole("button", { name: "Mover etapa" }));
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy/moves"))).toHaveLength(1));
    const stageMove = api.fetch.mock.calls.find(([path]) => String(path).endsWith("/hierarchy/moves"))!;
    expect(JSON.parse(stageMove[1]?.body as string)).toEqual({ kind: "stage", targetId: emptyStage.id,
      expectedVersion: emptyStage.version, destinationDisciplineId: destinationDiscipline.id, destinationStageId: null,
      destinationIndex: 0, expectedSourceOrder: [stage.id, emptyStage.id], expectedDestinationOrder: [] });

    fireEvent.click(screen.getByRole("button", { name: /Mover disciplina: Synthetic discipline/ }));
    const disciplineDialog = screen.getByRole("dialog", { name: "Mover disciplina" });
    fireEvent.change(within(disciplineDialog).getByLabelText("Posição"), { target: { value: "end" } });
    fireEvent.click(within(disciplineDialog).getByRole("button", { name: "Mover disciplina" }));
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy/moves"))).toHaveLength(2));
    const disciplineMove = api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy/moves"))[1]!;
    expect(JSON.parse(disciplineMove[1]?.body as string)).toEqual({ kind: "discipline", targetId: discipline.id,
      expectedVersion: discipline.version, destinationDisciplineId: null, destinationStageId: null,
      destinationIndex: 1, expectedSourceOrder: [discipline.id, destinationDiscipline.id],
      expectedDestinationOrder: [discipline.id, destinationDiscipline.id] });
  });

  it("shows discipline insertion and requests the new product order", async () => {
    setup({ productId: product.id, disciplines: [discipline, destinationDiscipline] });
    const { container } = render(<ScheduleEditor workspace={{ ...workspace, role: "editor" }} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    const draggedRow = container.querySelector<HTMLElement>(`[data-row-key="discipline:${destinationDiscipline.id}"]`)!;
    const targetRow = container.querySelector<HTMLElement>(`[data-row-key="discipline:${discipline.id}"]`)!;
    fireEvent.dragStart(within(draggedRow).getByRole("button", { name: /Mover disciplina: Empty destination/ }),
      { dataTransfer: { setData: vi.fn(), effectAllowed: "", dropEffect: "" } });
    fireEvent.dragOver(targetRow, { clientY: -1, dataTransfer: { dropEffect: "" } });
    expect(targetRow).toHaveClass("drop-before");
    expect(screen.getByText("Soltar disciplina antes de Synthetic discipline.")).toBeInTheDocument();
    fireEvent.drop(targetRow, { clientY: -1, dataTransfer: { dropEffect: "" } });
    await waitFor(() => expect(api.fetch.mock.calls.some(([path]) => String(path).endsWith("/hierarchy/moves"))).toBe(true));
    const moveCall = api.fetch.mock.calls.find(([path]) => String(path).endsWith("/hierarchy/moves"))!;
    expect(JSON.parse(moveCall[1]?.body as string)).toEqual({ kind: "discipline", targetId: destinationDiscipline.id,
      expectedVersion: destinationDiscipline.version, destinationDisciplineId: null, destinationStageId: null,
      destinationIndex: 0, expectedSourceOrder: [discipline.id, destinationDiscipline.id],
      expectedDestinationOrder: [discipline.id, destinationDiscipline.id] });
  });

  it("shows structural stale conflicts without changing the loaded order", async () => {
    const tree = { productId: product.id, disciplines: [discipline, destinationDiscipline] };
    api.fetch.mockImplementation((path: string) => path.endsWith("/hierarchy/moves")
      ? Promise.resolve(json({ error: "stale" }, 409)) : path.endsWith("/hierarchy")
        ? Promise.resolve(json({ hierarchy: tree })) : path.endsWith("/targets")
          ? Promise.resolve(json({ targets: [] })) : path.endsWith("/calendar-impact")
            ? Promise.resolve(json({ calendarVersion: 0, impacts: [] })) : path.includes("/calendar?year=")
              ? Promise.resolve(json({ calendar: { version: 0, exceptions: [] } }))
              : Promise.resolve(json({ stageDefinitions: definitions })));
    const { container } = render(<ScheduleEditor workspace={{ ...workspace, role: "editor" }} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    const before = Array.from(container.querySelectorAll(".workspace-table-row.row-discipline"))
      .map((row) => row.getAttribute("data-row-key"));
    fireEvent.click(screen.getByRole("button", { name: /Mover disciplina: Synthetic discipline/ }));
    const dialog = screen.getByRole("dialog", { name: "Mover disciplina" });
    fireEvent.click(within(dialog).getByRole("button", { name: "Mover disciplina" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("A ordem do cronograma mudou. Atualize os dados e tente novamente.");
    expect(Array.from(container.querySelectorAll(".workspace-table-row.row-discipline"))
      .map((row) => row.getAttribute("data-row-key"))).toEqual(before);
  });

  it("blocks a stale deletion fingerprint and fetches a new preview before allowing retry", async () => {
    let previewCount = 0;
    const summaryRefresh = vi.fn(async () => undefined);
    api.fetch.mockImplementation((path: string) => {
      if (path.endsWith("/hierarchy/deletions")) return Promise.resolve(json({ error: "stale" }, 409));
      if (path.includes("/deletion-preview")) return Promise.resolve(json({ fingerprint: (++previewCount).toString(16).padStart(32, "0"),
        counts: { disciplines: 0, stages: 0, activities: 1 } }));
      if (path.endsWith("/hierarchy")) return Promise.resolve(json({ hierarchy: { productId: product.id, disciplines: [discipline] } }));
      if (path.endsWith("/targets")) return Promise.resolve(json({ targets: [] }));
      if (path.endsWith("/calendar-impact")) return Promise.resolve(json({ calendarVersion: 0, impacts: [] }));
      if (path.includes("/calendar?year=")) return Promise.resolve(json({ calendar: { version: 0, exceptions: [] } }));
      return Promise.resolve(json({ stageDefinitions: definitions }));
    });
    mount("editor", summaryRefresh);
    fireEvent.click(await screen.findByRole("button", { name: "Excluir atividade: Synthetic activity" }));
    const dialog = await screen.findByRole("alertdialog", { name: "Confirmar exclusão do cronograma" });
    fireEvent.change(within(dialog).getByLabelText("Justificativa da exclusão"), {
      target: { value: "Remoção sintética com prévia desatualizada" }
    });
    fireEvent.click(within(dialog).getByRole("button", { name: "Excluir do cronograma" }));
    expect(await within(dialog).findByRole("alert")).toHaveTextContent(/A estrutura mudou desde a prévia/);
    expect(within(dialog).getByRole("button", { name: "Excluir do cronograma" })).toBeDisabled();
    expect(summaryRefresh).not.toHaveBeenCalled();
    fireEvent.click(within(dialog).getByRole("button", { name: "Atualizar prévia" }));
    await waitFor(() => expect(previewCount).toBe(2));
    expect(within(dialog).queryByText(/A estrutura mudou desde a prévia/)).not.toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: "Excluir do cronograma" })).toBeEnabled();
  });

  it("lets editors select date changes, excludes version-only rows, and submits only IDs and versions after confirmation", async () => {
    const second = { ...workingActivity, id: "02eb3d51-f256-4b9a-b939-a44ec2149906", name: "Second activity" };
    const versionOnly = { ...workingActivity, id: "4c3c7b16-9ff4-41f7-8835-11b2b26966dd", name: "Version-only activity" };
    const tree = { productId: product.id, disciplines: [{ ...discipline, stages: [{ ...stage,
      activities: [workingActivity, second, versionOnly] }] }] };
    setupImpacts([dateImpact, { ...dateImpact, activityId: second.id },
      { ...dateImpact, activityId: versionOnly.id, impact: "version_only",
        proposedEndDate: dateImpact.currentEndDate }], tree);
    mount("editor");
    fireEvent.click(await screen.findByRole("button", { name: "Revisar impactos" }));
    const panel = screen.getByRole("dialog", { name: "Prévia de impactos do calendário" });
    expect(within(panel).getByText("0 de 2 selecionadas")).toBeInTheDocument();
    expect(within(panel).getAllByText(/pontos facultativos não está verificada/)).toHaveLength(3);
    expect(within(panel).getByText("Para consultar ou reverter uma reprogramação, abra o histórico de reprogramações.")).toBeInTheDocument();
    expect(within(panel).getByText("Version-only activity").closest("li")?.querySelector("input")).toBeNull();
    const apply = within(panel).getByRole("button", { name: "Reprogramar selecionadas" });
    expect(apply).toBeDisabled();
    fireEvent.click(within(panel).getByRole("checkbox", { name: "Synthetic activity" }));
    expect(within(panel).getByText("1 de 2 selecionadas")).toBeInTheDocument();
    fireEvent.click(within(panel).getByRole("checkbox", { name: "Selecionar todas" }));
    expect(within(panel).getByText("2 de 2 selecionadas")).toBeInTheDocument();
    fireEvent.click(within(panel).getByRole("checkbox", { name: "Second activity" }));
    expect(within(panel).getByText("1 de 2 selecionadas")).toBeInTheDocument();
    fireEvent.change(within(panel).getByLabelText(/Justificativa da alteração/),
      { target: { value: "Ajuste sintético do calendário" } });
    fireEvent.click(apply);
    const dialog = screen.getByRole("alertdialog", { name: "Confirmar reprogramação" });
    expect(within(dialog).getByText(/Reprogramar 1 atividade selecionada/)).toBeInTheDocument();
    expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/calendar-impact/apply"))).toHaveLength(0);
    fireEvent.click(within(dialog).getByRole("button", { name: "Cancelar" }));
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/calendar-impact/apply"))).toHaveLength(0);
    fireEvent.click(apply);
    fireEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Confirmar reprogramação" }));
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/calendar-impact/apply"))).toHaveLength(1));
    const call = api.fetch.mock.calls.find(([path]) => String(path).endsWith("/calendar-impact/apply"))!;
    expect(call[1]).toMatchObject({ method: "POST" });
    expect(JSON.parse(call[1].body as string)).toEqual({ calendarVersion: 2,
      reason: "Ajuste sintético do calendário", selections: [{ activityId: activity.id, version: 3 }] });
  });

  it("keeps impact review read-only for viewers", async () => {
    setupImpacts([dateImpact]);
    mount("viewer");
    fireEvent.click(await screen.findByRole("button", { name: "Revisar impactos" }));
    const panel = screen.getByRole("dialog");
    expect(within(panel).queryByRole("checkbox")).not.toBeInTheDocument();
    expect(within(panel).queryByRole("button", { name: "Reprogramar selecionadas" })).not.toBeInTheDocument();
    expect(within(panel).getByRole("button", { name: "Agora não" })).toBeInTheDocument();
  });

  it("renders impact activities as full-width labels with a separate checkbox column", async () => {
    const second = { ...workingActivity, id: "02eb3d51-f256-4b9a-b939-a44ec2149906", name: "Second synthetic activity" };
    const versionOnly = { ...workingActivity, id: "4c3c7b16-9ff4-41f7-8835-11b2b26966dd", name: "Version-only activity" };
    const tree = { productId: product.id, disciplines: [{ ...discipline, stages: [{ ...stage,
      activities: [workingActivity, second, versionOnly] }] }] };
    setupImpacts([dateImpact, { ...dateImpact, activityId: second.id },
      { ...dateImpact, activityId: versionOnly.id, impact: "version_only",
        proposedStartDate: dateImpact.currentStartDate, proposedEndDate: dateImpact.currentEndDate }], tree);
    mount("editor");
    fireEvent.click(await screen.findByRole("button", { name: "Revisar impactos" }));
    const panel = screen.getByRole("dialog", { name: "Prévia de impactos do calendário" });
    const listRegion = within(panel).getByRole("region");
    const rows = panel.querySelectorAll(".calendar-impact-list > li");
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      const label = row.querySelector("h4 label.calendar-impact-activity");
      expect(label).toBeInTheDocument();
      const checkbox = label?.querySelector("input[type=checkbox]");
      const title = label?.querySelector(".calendar-impact-activity__name");
      expect(checkbox).toBeInTheDocument();
      expect(title).toBeInTheDocument();
      expect(label?.children).toHaveLength(2);
      expect(label?.children[0]).toBe(checkbox);
      expect(checkbox?.nextElementSibling).toBe(title);
      expect(row.querySelectorAll(".calendar-impact-dates > p")).toHaveLength(2);
      expect(row.querySelector(".calendar-impact-dates")).toHaveTextContent("Término atual: 10/11/2026");
      expect(row.querySelector(".calendar-impact-dates")).toHaveTextContent("Término proposto: 11/11/2026");
      expect(row.querySelector(".calendar-impact-meta")).toBeInTheDocument();
      expect(row.querySelector(".calendar-impact-meta")).toHaveTextContent("Versão do calendário: 1 → 2");
      expect(row.querySelector(".calendar-impact-warning")).toHaveTextContent("2026");
    }
    expect(listRegion).toHaveAttribute("tabindex", "0");
    const selection = panel.querySelector(".calendar-impact-selection");
    expect(selection?.children).toHaveLength(2);
    expect(selection?.querySelector("label")).toHaveTextContent("Selecionar todas");
    expect(selection?.querySelector("label input + span")).toBeInTheDocument();
    expect(selection?.querySelector(".calendar-impact-selection__count")).toHaveTextContent("0 de 2 selecionadas");
    const versionOnlySection = panel.querySelector(".calendar-impact-version-only");
    expect(versionOnlySection).toBeInTheDocument();
    expect(versionOnlySection).not.toHaveAttribute("open");
    expect(versionOnlySection?.querySelector("summary")).toHaveTextContent(/1\)/);
    expect(versionOnlySection?.querySelector("li input[type=checkbox]")).toBeNull();
    expect(panel.querySelectorAll(".calendar-impact-version-only__list > li")).toHaveLength(1);
    const footer = panel.querySelector(".calendar-impact-panel__footer");
    expect(footer?.querySelector("textarea#calendar-impact-reason")).toBeInTheDocument();
    expect(footer?.querySelector("button")).toHaveTextContent("Reprogramar selecionadas");
  });

  it("waits for server success before refreshing dates and blocks duplicate submissions", async () => {
    setupImpacts([dateImpact]);
    const fallback = api.fetch.getMockImplementation()!;
    let resolveApply!: (response: Response) => void;
    const pending = new Promise<Response>((resolve) => { resolveApply = resolve; });
    let changed = false;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => {
      if (path.endsWith("/calendar-impact/apply")) return pending;
      if (path.endsWith("/hierarchy") && changed) return Promise.resolve(json({ hierarchy: {
        productId: product.id, disciplines: [{ ...discipline, stages: [{ ...stage,
          activities: [{ ...workingActivity, plannedEnd: "2026-11-11", version: 4,
            planningCalendarVersion: 2 }] }] }] } }));
      if (path.endsWith("/calendar-impact") && changed) return Promise.resolve(json({ calendarVersion: 2, impacts: [] }));
      return fallback(path, options);
    });
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Revisar impactos" }));
    const panel = screen.getByRole("dialog");
    fireEvent.click(within(panel).getByRole("checkbox", { name: "Synthetic activity" }));
    fireEvent.change(within(panel).getByLabelText(/Justificativa da alteração/),
      { target: { value: "Ajuste sintético do calendário" } });
    fireEvent.click(within(panel).getByRole("button", { name: "Reprogramar selecionadas" }));
    fireEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Confirmar reprogramação" }));
    expect(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Reprogramando…" })).toBeDisabled();
    expect(within(panel).getByText("Término atual: 10/11/2026")).toBeInTheDocument();
    expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/calendar-impact/apply"))).toHaveLength(1);
    changed = true;
    resolveApply(json({ changedCount: 1, operationId: "synthetic" }));
    expect(await screen.findByText("1 atividade reprogramada com registro de auditoria.")).toBeInTheDocument();
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy")).length)
      .toBeGreaterThan(1));
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/calendar-impact")).length)
      .toBeGreaterThan(1));
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });

  it("invalidates stale proposals and reports authorization loss", async () => {
    setupImpacts([dateImpact]);
    const fallback = api.fetch.getMockImplementation()!;
    let applyStatus = 409;
    api.fetch.mockImplementation((path: string, options?: RequestInit) =>
      path.endsWith("/calendar-impact/apply") ? Promise.resolve(json({}, applyStatus)) : fallback(path, options));
    const onAccessLost = mount();
    fireEvent.click(await screen.findByRole("button", { name: "Revisar impactos" }));
    const panel = screen.getByRole("dialog");
    fireEvent.click(within(panel).getByRole("checkbox", { name: "Synthetic activity" }));
    fireEvent.change(within(panel).getByLabelText(/Justificativa da alteração/),
      { target: { value: "Ajuste sintético do calendário" } });
    fireEvent.click(within(panel).getByRole("button", { name: "Reprogramar selecionadas" }));
    fireEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Confirmar reprogramação" }));
    expect(await within(panel).findByText("O calendário ou uma atividade mudou. Atualize a prévia antes de tentar novamente.")).toBeInTheDocument();
    expect(within(panel).queryByRole("checkbox")).not.toBeInTheDocument();
    applyStatus = 403;
    fireEvent.click(within(panel).getByRole("button", { name: "Atualizar prévia" }));
    fireEvent.click(await within(panel).findByRole("checkbox", { name: "Synthetic activity" }));
    fireEvent.click(within(panel).getByRole("button", { name: "Reprogramar selecionadas" }));
    fireEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Confirmar reprogramação" }));
    await waitFor(() => expect(onAccessLost).toHaveBeenCalledTimes(1));
  });

  it("keeps the preview and selection available after a temporary apply failure", async () => {
    setupImpacts([dateImpact]);
    const fallback = api.fetch.getMockImplementation()!;
    api.fetch.mockImplementation((path: string, options?: RequestInit) =>
      path.endsWith("/calendar-impact/apply") ? Promise.reject(new Error("network unavailable"))
        : fallback(path, options));
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Revisar impactos" }));
    const panel = screen.getByRole("dialog");
    fireEvent.click(within(panel).getByRole("checkbox", { name: "Synthetic activity" }));
    fireEvent.change(within(panel).getByLabelText(/Justificativa da alteração/),
      { target: { value: "Ajuste sintético do calendário" } });
    fireEvent.click(within(panel).getByRole("button", { name: "Reprogramar selecionadas" }));
    fireEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Confirmar reprogramação" }));
    expect(await within(panel).findByText("Não foi possível reprogramar as atividades. Tente novamente.")).toBeInTheDocument();
    expect(within(panel).getByRole("checkbox", { name: "Synthetic activity" })).toBeChecked();
    expect(within(panel).getByText("Término atual: 10/11/2026")).toBeInTheDocument();
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/hierarchy"))).toHaveLength(1);
  });
  it("reviews date and version impacts without writing or overlaying manual activities", async () => {
    const manual = { ...activity, id: "4c3c7b16-9ff4-41f7-8835-11b2b26966dd", name: "Manual activity" };
    const second = { ...workingActivity, id: "02eb3d51-f256-4b9a-b939-a44ec2149906",
      name: "Version-only activity" };
    const tree = { productId: product.id, disciplines: [{ ...discipline, stages: [{ ...stage,
      activities: [workingActivity, second, manual] }] }] };
    setupImpacts([dateImpact, { ...dateImpact, activityId: second.id, impact: "version_only",
      proposedEndDate: dateImpact.currentEndDate, optionalDaysVerified: true,
      unverifiedOptionalYears: [] }], tree);
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    expect(await screen.findByText("1 atividade com alteração de data proposta")).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("pontos facultativos não está verificada para 2026");
    expect(container.querySelector(".timeline-proposed-bar")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Revisar impactos" }));
    const panel = screen.getByRole("dialog", { name: "Prévia de impactos do calendário" });
    expect(within(panel).getByText("Synthetic activity")).toBeInTheDocument();
    expect(within(panel).getByText("Version-only activity")).toBeInTheDocument();
    expect(within(panel).queryByText("Manual activity")).not.toBeInTheDocument();
    expect(within(panel).getAllByText("Término atual: 10/11/2026")).toHaveLength(2);
    expect(within(panel).getByText("Término proposto: 11/11/2026")).toBeInTheDocument();
    expect(within(panel).getByText("Versão mudou; datas mantidas")).toBeInTheDocument();
    expect(within(panel).getByText(/não está verificada para 2026/)).toBeInTheDocument();
    expect(container.querySelectorAll(".timeline-proposed-bar")).toHaveLength(1);
    expect(container.querySelector(".timeline-proposed-bar")).toHaveAttribute("data-activity-id", activity.id);
    expect(api.fetch).not.toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ method: expect.stringMatching(/POST|PATCH|PUT|DELETE/) }));
    fireEvent.click(within(panel).getByRole("button", { name: "Agora não" }));
    expect(screen.queryByRole("dialog", { name: "Prévia de impactos do calendário" })).not.toBeInTheDocument();
    expect(container.querySelector(".timeline-proposed-bar")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Revisar impactos" })).toBeInTheDocument();
  });

  it("suppresses the impact notice for version-only changes while surfacing coverage warnings", async () => {
    const versionOnly = { ...dateImpact, impact: "version_only" as const,
      proposedStartDate: dateImpact.currentStartDate, proposedEndDate: dateImpact.currentEndDate,
      optionalDaysVerified: false, unverifiedOptionalYears: [2027] };
    setupImpacts([versionOnly]);
    render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await waitFor(() => expect(api.fetch.mock.calls.some(([path]) => String(path).endsWith("/calendar-impact"))).toBe(true));
    expect(await screen.findByText(/pontos facultativos não está verificada para 2027/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Revisar impactos" })).not.toBeInTheDocument();
    expect(screen.queryByText(/atividade com alteração de data proposta/)).not.toBeInTheDocument();
    expect(screen.queryByRole("dialog", { name: "Prévia de impactos do calendário" })).not.toBeInTheDocument();
    expect(api.fetch).not.toHaveBeenCalledWith(expect.anything(), expect.objectContaining({
      method: expect.stringMatching(/POST|PATCH|PUT|DELETE/)
    }));
  });

  it("counts actual proposed date changes in the review notification", async () => {
    setupImpacts([dateImpact]);
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    expect(await screen.findByText("1 atividade com alteração de data proposta")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Revisar impactos" })).toBeInTheDocument();
    expect(container.querySelector(".timeline-proposed-bar")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Revisar impactos" }));
    expect(container.querySelector(".timeline-proposed-bar")).toBeInTheDocument();
  });

  it("closes an open review when refreshed results are version-only", async () => {
    let impacts: ActivityCalendarImpact[] = [dateImpact];
    setup(workingTree);
    const fallback = api.fetch.getMockImplementation()!;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => path.endsWith("/calendar-impact")
      ? Promise.resolve(json({ calendarVersion: 2, impacts })) : fallback(path, options));
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "Revisar impactos" }));
    impacts = [{ ...dateImpact, impact: "version_only", proposedStartDate: dateImpact.currentStartDate,
      proposedEndDate: dateImpact.currentEndDate, optionalDaysVerified: true, unverifiedOptionalYears: [] }];
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Atualizar prévia" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Revisar impactos" })).not.toBeInTheDocument());
    expect(container.querySelector(".timeline-proposed-bar")).not.toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("shows a retryable error and suppresses stale overlays on a failed refresh", async () => {
    setupImpacts([dateImpact]);
    const fallback = api.fetch.getMockImplementation()!;
    let fail = false;
    api.fetch.mockImplementation((path: string, options?: RequestInit) =>
      path.endsWith("/calendar-impact") && fail ? Promise.resolve(json({}, 503)) : fallback(path, options));
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "Revisar impactos" }));
    fail = true;
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Atualizar prévia" }));
    expect(await screen.findAllByText("Não foi possível carregar os impactos do calendário. Tente novamente.")).toHaveLength(2);
    expect(container.querySelector(".timeline-proposed-bar")).not.toBeInTheDocument();
    fail = false;
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Atualizar prévia" }));
    await waitFor(() => expect(container.querySelector(".timeline-proposed-bar")).toBeInTheDocument());
  });

  it("withholds mismatched activity proposals and requests fresh schedule data", async () => {
    setupImpacts([{ ...dateImpact, activityVersion: 2 }]);
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    expect(await screen.findByText("O cronograma mudou desde o cálculo da prévia. Atualize os dados para revisar os impactos.")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Revisar impactos" })).not.toBeInTheDocument();
    expect(container.querySelector(".timeline-proposed-bar")).not.toBeInTheDocument();
    fireEvent.click(screen.getAllByRole("button", { name: "Atualizar dados" })[0]);
    await waitFor(() => expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/calendar-impact")).length)
      .toBeGreaterThan(1));
  });

  it("uses a compact product breadcrumb and keeps schedule actions in the workspace toolbar", async () => {
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    expect(screen.getByRole("heading", { name: "Synthetic product", level: 2 })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Voltar aos produtos" })).toHaveTextContent("Produtos");
    const toolbar = container.querySelector<HTMLElement>(".workspace-controls")!;
    expect(within(toolbar).getByRole("button", { name: "Adicionar disciplina" }) as HTMLElement).toBeInTheDocument();
    expect(within(toolbar).getByRole("button", { name: "Atualizar dados" }) as HTMLElement).toBeInTheDocument();
    expect(within(toolbar).getByRole("group", { name: "Escala" }).querySelectorAll("button")).toHaveLength(3);
    expect(container.querySelector(".schedule-editor > .schedule-toolbar")).not.toBeInTheDocument();
  });

  it("shares visible row order, selection, and expansion between the table and Gantt", async () => {
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    const keys = (selector: string) => [...container.querySelectorAll<HTMLElement>(selector)]
      .map((element) => element.dataset.rowKey);
    expect(keys(".workspace-table-row")).toEqual(keys(".workspace-chart-row"));
    fireEvent.click(screen.getByRole("button", { name: "Synthetic activity" }));
    expect(container.querySelectorAll(".selected[data-row-key='activity:cd960302-0b68-4621-95ed-7d4f57f8eedc']")).toHaveLength(2);
    fireEvent.click(screen.getByRole("button", { name: "Expandir ou recolher Synthetic discipline" }));
    expect(keys(".workspace-table-row")).toEqual(keys(".workspace-chart-row"));
    expect(keys(".workspace-table-row")).toHaveLength(2);
  });

  it("positions target markers, changes zoom, and resizes the split by keyboard", async () => {
    setup(undefined, [{ id: "target", name: "Synthetic target", targetDate: "2026-11-05",
      operationalDate: null, displayOrder: 0 }]);
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    expect(container.querySelectorAll(".timeline-target-line")).toHaveLength(1);
    const chart = container.querySelector<HTMLElement>(".workspace-chart-content")!;
    const weekWidth = parseInt(chart.style.width);
    fireEvent.click(screen.getByRole("button", { name: "Dia" }));
    expect(parseInt(chart.style.width)).toBeGreaterThan(weekWidth);
    fireEvent.click(screen.getByRole("button", { name: "Mês" }));
    expect(parseInt(chart.style.width)).toBeLessThan(weekWidth);
    const separator = screen.getByRole("separator");
    expect(separator).toHaveAttribute("aria-valuenow", "50");
    fireEvent.keyDown(separator, { key: "ArrowRight" });
    expect(separator).toHaveAttribute("aria-valuenow", "55");
  });

  it("opens edits in a focused side panel without changing the schedule scroll position", async () => {
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    const body = container.querySelector<HTMLElement>(".workspace-body")!;
    body.scrollTop = 120;
    fireEvent.click(screen.getByRole("button", { name: "Editar atividade" }));
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(within(screen.getByRole("dialog")).getByRole("heading", { name: "Editar atividade" })).toBeInTheDocument();
    expect(container.querySelector(".schedule-drawer__footer")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByLabelText("Nome da atividade")).toHaveFocus());
    expect(body.scrollTop).toBe(120);
    fireEvent.keyDown(window, { key: "Escape" });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(body.scrollTop).toBe(120);
    expect(api.fetch).not.toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ method: "PATCH" }));
  });

  it("loads ordered hierarchy, Brazilian dates, derived dates, and collapses rows", async () => {
    mount();
    expect(screen.getByRole("status")).toHaveTextContent("Carregando cronograma");
    expect(await screen.findByText("Synthetic activity")).toBeInTheDocument();
    expect(screen.getAllByText("01/11/2026")).toHaveLength(4);
    expect(screen.getAllByText("08/11/2026")).toHaveLength(4);
    fireEvent.click(screen.getByRole("button", { name: "Expandir ou recolher Synthetic discipline" }));
    expect(screen.queryByText("Synthetic activity")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Expandir ou recolher Synthetic discipline" })).toHaveAttribute("aria-expanded", "false");
  });

  it("shows empty groups and gives viewers read-only access", async () => {
    setup({ productId: product.id, disciplines: [{ ...discipline, stages: [{ ...stage, activities: [], derivedStart: null, derivedEnd: null }] }] });
    mount("viewer");
    expect(await screen.findByText("Nenhuma atividade cadastrada nesta etapa.")).toBeInTheDocument();
    expect(screen.getAllByText("Sem data").length).toBeGreaterThan(0);
    expect(screen.queryByRole("button", { name: "Adicionar atividade" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Editar etapa" })).not.toBeInTheDocument();
    expect(api.fetch).not.toHaveBeenCalledWith(expect.stringContaining("stage-definitions"));
  });

  it("creates a discipline with ordered metadata", async () => {
    mount("editor");
    fireEvent.click(await screen.findByRole("button", { name: "Adicionar disciplina" }));
    fireEvent.change(screen.getByLabelText("Nome da disciplina"), { target: { value: "Nova disciplina" } });
    fireEvent.change(screen.getByLabelText("Código da disciplina"), { target: { value: "NEW" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/products/${product.id}/disciplines`,
      expect.objectContaining({ method: "POST", body: expect.stringContaining('"shortCode":"NEW"') })
    ));
  });

  it("confirms a discipline metadata edit with its current version", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Editar disciplina" }));
    fireEvent.change(screen.getByLabelText("Ordem de exibição"), { target: { value: "3" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/disciplines/${discipline.id}`),
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"version":1') })
    ));
    expect(confirmation).toHaveBeenCalled();
    confirmation.mockRestore();
  });

  it("selects a shared stage definition and preserves its color", async () => {
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Adicionar etapa" }));
    fireEvent.change(screen.getByLabelText("Código compartilhado da etapa"), { target: { value: definitions[0].id } });
    expect(screen.getByText("Alterar e salvar esta cor afeta todas as etapas que usam a definição EC.")).toBeInTheDocument();
    expect(screen.getByLabelText("Código hexadecimal")).toHaveValue("#336699");
    fireEvent.change(screen.getByLabelText("Nome da etapa"), { target: { value: "Nova etapa" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/disciplines/${discipline.id}/stages`),
      expect.objectContaining({ method: "POST", body: expect.stringContaining('"color":"#336699"') })
    ));
  });

  it("edits a stage using its shared definition and version", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Editar etapa" }));
    expect(screen.getByRole("combobox", { name: "Código compartilhado da etapa" })).toHaveValue(definitions[0].id);
    fireEvent.change(screen.getByLabelText("Nome da etapa"), { target: { value: "Etapa atualizada" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/stages/${stage.id}`),
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"version":1') })
    ));
    confirmation.mockRestore();
  });

  it("saves a shared color with optimistic concurrency and refreshes current Gantt rows", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    let sharedColor = "#336699";
    api.fetch.mockImplementation((path: string, options?: RequestInit) => {
      if (path.endsWith("/calendar-impact")) return Promise.resolve(json({ calendarVersion: 0, impacts: [] }));
      if (path.endsWith("/stage-definitions"))
        return Promise.resolve(json({ stageDefinitions: [{ ...definitions[0], color: sharedColor }] }));
      if (path.endsWith("/hierarchy")) return Promise.resolve(json({ hierarchy: { productId: product.id,
        disciplines: [{ ...discipline, stages: [{ ...stage, color: sharedColor, activities: [activity] }] }] } }));
      if (path.includes("/stage-definitions/") && options?.method === "PATCH") {
        const input = JSON.parse(String(options.body)) as { expectedColor: string; color: string };
        expect(input.expectedColor).toBe(sharedColor);
        sharedColor = input.color;
        return Promise.resolve(json({ stageDefinition: { ...definitions[0], color: sharedColor } }));
      }
      return Promise.resolve(path.endsWith("/targets") ? json({ targets: [] }) : json({ changes: [] }));
    });
    const { container } = render(<ScheduleEditor workspace={workspace} product={product} userId={userId}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "Editar etapa" }));
    fireEvent.change(screen.getByLabelText("Código hexadecimal"), { target: { value: "#AA5577" } });
    expect(screen.getByText("Alterar e salvar esta cor afeta todas as etapas que usam a definição EC.")).toBeInTheDocument();
    expect(readRecentCustomColors(userId)).toEqual([]);
    fireEvent.click(screen.getByRole("button", { name: "Salvar cor compartilhada" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/stage-definitions/${definitions[0].id}`,
      expect.objectContaining({ method: "PATCH", body: JSON.stringify({ color: "#AA5577", expectedColor: "#336699" }) })
    ));
    expect(await screen.findByRole("alert")).toHaveTextContent("Cor compartilhada atualizada");
    expect(container.querySelector(".workspace-table-row.row-stage .color-chip")).toHaveStyle({ backgroundColor: "#AA5577" });
    expect(container.querySelector(".timeline-bar.bar-activity")).toHaveStyle({ backgroundColor: "#AA5577" });
    expect(confirmation).toHaveBeenCalledWith(expect.stringContaining("todas as etapas"));
    await waitFor(() => expect(readRecentCustomColors(userId)).toEqual(["#AA5577"]));
    confirmation.mockRestore();
  });

  it("validates activity dates and sends ISO civil dates only on creation", async () => {
    mount();
    fireEvent.click((await screen.findAllByRole("button", { name: "Adicionar atividade" })).at(-1)!);
    fireEvent.change(screen.getByLabelText("Nome da atividade"), { target: { value: "Nova atividade" } });
    fireEvent.change(screen.getByLabelText("Início planejado"), { target: { value: "31/02/2026" } });
    fireEvent.change(screen.getByLabelText("Fim planejado"), { target: { value: "08/11/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    expect(screen.getByRole("alert")).toHaveTextContent("Informe as duas datas");
    fireEvent.change(screen.getByLabelText("Início planejado"), { target: { value: "01/11/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/stages/${stage.id}/activities`),
      expect.objectContaining({ method: "POST", body: expect.stringContaining('"plannedStart":"2026-11-01"') })
    ));
  });

  it("previews and creates an inclusive working-day activity with calendar metadata", async () => {
    const original = api.fetch.getMockImplementation();
    const preview = { startDate: "2026-11-06", endDate: "2026-11-10", workingDays: 2,
      calendarVersion: 7, optionalDaysVerified: true, unverifiedOptionalYears: [],
      skippedDates: [{ date: "2026-11-07", reasons: [{ kind: "weekend", code: "saturday" }] }] };
    api.fetch.mockImplementation((path: string, options?: RequestInit) => path.includes("working-day-preview")
      ? Promise.resolve(json({ preview })) : original!(path, options));
    mount("editor");
    fireEvent.click((await screen.findAllByRole("button", { name: "Adicionar atividade" })).at(-1)!);
    fireEvent.change(screen.getByLabelText("Nome da atividade"), { target: { value: "Synthetic working activity" } });
    fireEvent.change(screen.getByLabelText("Modo de planejamento"), { target: { value: "working_days" } });
    fireEvent.change(screen.getByLabelText("Início planejado"), { target: { value: "06/11/2026" } });
    fireEvent.change(screen.getByLabelText("Duração em dias úteis"), { target: { value: "2" } });
    fireEvent.click(screen.getByRole("button", { name: "Calcular término" }));
    expect(await screen.findByText("10/11/2026")).toBeInTheDocument();
    expect(screen.getByText(/1 dia\(s\) não útil\(eis\) considerado\(s\)/)).toBeInTheDocument();
    expect(screen.getByText(/07\/11\/2026/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/stages/${stage.id}/activities`),
      expect.objectContaining({ method: "POST", body: JSON.stringify({
        name: "Synthetic working activity", activityType: null, displayOrder: 0, notes: null,
        planningMode: "working_days", plannedStart: "2026-11-06", workingDays: 2, calendarVersion: 7
      }) })
    ));
  });

  it("edits an existing activity in working-day mode with a mandatory reason and server version", async () => {
    const existing = { ...activity, plannedStart: "2026-11-05", plannedEnd: "2026-11-10", version: 2,
      planningMode: "working_days" as const, workingDayDuration: 3, planningCalendarVersion: 7 };
    let current = existing;
    const previewFor = (startDate: string, workingDays: number) => ({ startDate,
      endDate: workingDays === 4 ? "2026-11-11" : "2026-11-10", workingDays,
      calendarVersion: 8, optionalDaysVerified: false, unverifiedOptionalYears: [2027], skippedDates: [] });
    api.fetch.mockImplementation((path: string, options?: RequestInit) => {
      if (path.endsWith("/calendar-impact")) return Promise.resolve(json({ calendarVersion: 0, impacts: [] }));
      if (path.includes("working-day-preview")) {
        const url = new URL(path, "https://app.test");
        return Promise.resolve(json({ preview: previewFor(url.searchParams.get("startDate")!,
          Number(url.searchParams.get("workingDays"))) }));
      }
      if (path.endsWith("/working-plan") && options?.method === "PATCH") {
        current = { ...current, plannedEnd: "2026-11-11", workingDayDuration: 4,
          planningCalendarVersion: 8, version: 3 };
        return Promise.resolve(json({ activity: current, changed: true }));
      }
      if (path.endsWith("/hierarchy")) return Promise.resolve(json({ hierarchy: { productId: product.id,
        disciplines: [{ ...discipline, stages: [{ ...stage, derivedStart: current.plannedStart,
          derivedEnd: current.plannedEnd, activities: [current] }] }] } }));
      if (path.includes("/change-history")) return Promise.resolve(json({ events: [], nextCursor: null }));
      return Promise.resolve(path.endsWith("/targets") ? json({ targets: [] }) : json({ stageDefinitions: definitions }));
    });
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Editar atividade" }));
    expect(await screen.findByText(/pontos facultativos não está verificada para 2027/)).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Duração em dias úteis"), { target: { value: "4" } });
    fireEvent.click(screen.getByRole("button", { name: "Calcular término" }));
    expect(await screen.findByText("11/11/2026")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Salvar datas" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(/justificativa com pelo menos 10 caracteres/);
    fireEvent.change(screen.getByLabelText("Justificativa da alteração"),
      { target: { value: "Synthetic working-day adjustment" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar datas" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/activities/${activity.id}/working-plan`),
      expect.objectContaining({ method: "PATCH", body: JSON.stringify({ startDate: "2026-11-05",
        workingDays: 4, calendarVersion: 8, reason: "Synthetic working-day adjustment", version: 2 }) })
    ));
  });

  it("keeps metadata and date changes separate and confirms metadata edits", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Editar atividade" }));
    expect(screen.getByText(/Alterações de datas ou modo de planejamento exigem justificativa/)).toBeInTheDocument();
    expect(screen.getByLabelText("Início planejado")).toHaveValue("01/11/2026");
    fireEvent.change(screen.getByLabelText("Nome da atividade"), { target: { value: "Atualizada" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar dados" }));
    await waitFor(() => expect(confirmation).toHaveBeenCalled());
    const mutation = api.fetch.mock.calls.find(([path, options]) => path.endsWith(`/activities/${activity.id}`) && options?.method === "PATCH");
    expect(mutation?.[1].body).toContain('"version":1');
    expect(mutation?.[1].body).not.toContain("plannedStart");
    confirmation.mockRestore();
  });

  it("edits and restores an activity color in the draft while the Gantt uses the saved effective color", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    let current: Omit<typeof activity, "colorOverride"> & { colorOverride: string | null } = { ...activity };
    api.fetch.mockImplementation((path: string, options?: RequestInit) => {
      if (path.endsWith("/calendar-impact")) return Promise.resolve(json({ calendarVersion: 0, impacts: [] }));
      if (path.endsWith("/hierarchy")) return Promise.resolve(json({ hierarchy: { productId: product.id,
        disciplines: [{ ...discipline, stages: [{ ...stage, activities: [current] }] }] } }));
      if (path.endsWith(`/activities/${activity.id}`) && options?.method === "PATCH") {
        const input = JSON.parse(String(options.body)) as { colorOverride: string | null };
        current = { ...current, colorOverride: input.colorOverride, version: current.version + 1 };
        return Promise.resolve(json({ activity: current }));
      }
      return Promise.resolve(path.endsWith("/targets") ? json({ targets: [] }) : json({ stageDefinitions: definitions }));
    });
    const { container } = render(<ScheduleEditor workspace={workspace} product={product} userId={userId}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: "Editar atividade" }));
    expect(screen.queryByRole("radio", { name: "Herdar cor da etapa" })).not.toBeInTheDocument();
    expect(screen.queryByRole("radio", { name: "Usar cor personalizada" })).not.toBeInTheDocument();
    expect(screen.getByLabelText("Código hexadecimal")).toHaveValue("#336699");
    expect(screen.getByLabelText("Selecionar cor personalizada para Selecionar cor da atividade")).toHaveValue("#336699");
    expect(screen.getByText("Herdando cor da etapa (#336699).")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Selecionar cor #52694D" }));
    expect(screen.getByLabelText("Código hexadecimal")).toHaveValue("#52694D");
    expect(screen.getByLabelText("Selecionar cor personalizada para Selecionar cor da atividade")).toHaveValue("#52694d");
    expect(screen.getByText("Cor personalizada ativa (#52694D).")).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Código hexadecimal"), { target: { value: "#AA5577" } });
    expect(screen.getByLabelText("Código hexadecimal")).toHaveValue("#AA5577");
    expect(screen.getByLabelText("Selecionar cor personalizada para Selecionar cor da atividade")).toHaveValue("#aa5577");
    expect(screen.getByText("Cor personalizada ativa (#AA5577).")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Restaurar cor da etapa" })).toBeInTheDocument();
    expect(readRecentCustomColors(userId)).toEqual([]);
    expect(api.fetch.mock.calls.some(([path, options]) => path.endsWith(`/activities/${activity.id}`) &&
      options?.method === "PATCH")).toBe(false);
    fireEvent.click(screen.getAllByRole("button", { name: "Cancelar" })[0]);
    expect(readRecentCustomColors(userId)).toEqual([]);
    fireEvent.click(screen.getByRole("button", { name: "Editar atividade" }));
    expect(screen.getByLabelText("Código hexadecimal")).toHaveValue("#336699");
    expect(screen.queryByRole("button", { name: "Restaurar cor da etapa" })).not.toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("Código hexadecimal"), { target: { value: "#AA5577" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar dados" }));
    await waitFor(() => expect(container.querySelector(".timeline-bar.bar-activity"))
      .toHaveStyle({ backgroundColor: "#AA5577" }));
    await waitFor(() => expect(readRecentCustomColors(userId)).toEqual(["#AA5577"]));
    const overrideCall = api.fetch.mock.calls.find(([path, options]) => path.endsWith(`/activities/${activity.id}`) &&
      options?.method === "PATCH" && String(options.body).includes('"colorOverride":"#AA5577"'));
    expect(overrideCall).toBeDefined();

    fireEvent.click(screen.getByRole("button", { name: "Editar atividade" }));
    expect(screen.getByLabelText("Código hexadecimal")).toHaveValue("#AA5577");
    fireEvent.click(screen.getByRole("button", { name: "Selecionar cor #AA5577" }));
    expect(screen.getByLabelText("Código hexadecimal")).toHaveValue("#AA5577");
    fireEvent.click(screen.getByRole("button", { name: "Restaurar cor da etapa" }));
    expect(screen.getByLabelText("Código hexadecimal")).toHaveValue("#336699");
    expect(screen.getByLabelText("Selecionar cor personalizada para Selecionar cor da atividade")).toHaveValue("#336699");
    expect(screen.getByText("Herdando cor da etapa (#336699).")).toBeInTheDocument();
    const patchesBeforeSave = api.fetch.mock.calls.filter(([path, options]) =>
      path.endsWith(`/activities/${activity.id}`) && options?.method === "PATCH").length;
    expect(patchesBeforeSave).toBe(1);
    fireEvent.click(screen.getByRole("button", { name: "Salvar dados" }));
    await waitFor(() => expect(container.querySelector(".timeline-bar.bar-activity"))
      .toHaveStyle({ backgroundColor: "#336699" }));
    expect(api.fetch.mock.calls.some(([path, options]) => path.endsWith(`/activities/${activity.id}`) &&
      options?.method === "PATCH" && String(options.body).includes('"colorOverride":null'))).toBe(true);
    expect(readRecentCustomColors(userId)).toEqual(["#AA5577"]);
    confirmation.mockRestore();
  });

  it("requires a reason, saves audited dates, refreshes stage and Gantt, and preserves workspace state", async () => {
    let current = activity;
    let historyEvents: unknown[] = [];
    api.fetch.mockImplementation((path: string, options?: RequestInit) => {
      if (path.endsWith("/calendar-impact")) return Promise.resolve(json({ calendarVersion: 0, impacts: [] }));
      if (path.includes("/change-history")) return Promise.resolve(json({ events: historyEvents, nextCursor: null }));
      if (path.endsWith("/dates") && options?.method === "PATCH") {
        current = { ...current, plannedStart: "2026-11-03", plannedEnd: "2026-11-10", version: 2 };
        historyEvents = [{ id: "activity-date:a7777777-7777-4777-8777-777777777777",
          occurredAt: "2026-11-09T12:00:00.000Z", actorId: "synthetic-actor", actorName: "Synthetic editor",
          eventType: "activity_dates_changed", item: { kind: "activity", id: activity.id,
            name: activity.name, hierarchy: { discipline: discipline.name, stage: stage.displayName } },
          justification: "Synthetic approved correction", before: { plannedStart: "2026-11-01", plannedEnd: "2026-11-08" },
          after: { plannedStart: current.plannedStart, plannedEnd: current.plannedEnd }, affectedItems: [] }];
        return Promise.resolve(json({ activity: current, changed: true }));
      }
      if (path.endsWith("/hierarchy")) return Promise.resolve(json({ hierarchy: { productId: product.id,
        disciplines: [{ ...discipline, stages: [{ ...stage, derivedStart: current.plannedStart,
          derivedEnd: current.plannedEnd, activities: [current] }] }] } }));
      if (path.endsWith("/targets")) return Promise.resolve(json({ targets: [] }));
      return Promise.resolve(json({ stageDefinitions: definitions }));
    });
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await screen.findByText("Synthetic activity");
    const body = container.querySelector<HTMLElement>(".workspace-body")!;
    body.scrollTop = 120;
    fireEvent.click(screen.getByRole("button", { name: "Mês" }));
    const initialLeft = container.querySelector<HTMLElement>(".timeline-bar.bar-activity")!.style.left;
    fireEvent.click(screen.getByRole("button", { name: "Editar atividade" }));
    fireEvent.change(screen.getByLabelText("Início planejado"), { target: { value: "03/11/2026" } });
    fireEvent.change(screen.getByLabelText("Fim planejado"), { target: { value: "10/11/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar datas" }));
    expect(screen.getByRole("alert")).toHaveTextContent("justificativa");
    expect(api.fetch).not.toHaveBeenCalledWith(expect.stringContaining("/dates"), expect.anything());
    fireEvent.change(screen.getByLabelText("Justificativa da alteração"),
      { target: { value: "Synthetic approved correction" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar datas" }));
    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("registradas no histórico"));
    expect(container.querySelector<HTMLElement>(".workspace-table-row.row-stage")!.textContent).toContain("10/11/2026");
    expect(container.querySelector<HTMLElement>(".timeline-bar.bar-activity")!.style.left).not.toBe(initialLeft);
    fireEvent.click(screen.getByRole("button", { name: "Ver log de alterações" }));
    expect(await screen.findByText("Synthetic approved correction")).toBeInTheDocument();
    expect(body.scrollTop).toBe(120);
    expect(screen.getByRole("button", { name: "Mês" })).toHaveAttribute("aria-pressed", "true");
    expect(container.querySelector(".workspace-table-row.row-activity")).toHaveClass("selected");
  });

  it("does not submit unchanged dates and lets viewers read history without edit controls", async () => {
    const first = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "Editar atividade" }));
    fireEvent.click(screen.getByRole("button", { name: "Salvar datas" }));
    expect(screen.getByRole("alert")).toHaveTextContent("não foram alteradas");
    expect(api.fetch).not.toHaveBeenCalledWith(expect.stringContaining("/dates"), expect.anything());
    fireEvent.keyDown(window, { key: "Escape" });
    first.unmount();
    setup(undefined, [{ id: "target", name: "Synthetic target", targetDate: "2026-11-05",
      operationalDate: null, displayOrder: 0 }]);
    const { unmount } = render(<ScheduleEditor workspace={{ ...workspace, role: "viewer" }} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: /Histórico de datas: Synthetic activity/ }));
    expect(await screen.findByText("Nenhum evento de auditoria foi registrado para este produto.")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Salvar datas" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Editar atividade" })).not.toBeInTheDocument();
    unmount();
  });

  it("shows a retryable history error without exposing a failed response", async () => {
    setup();
    const defaultFetch = api.fetch.getMockImplementation()!;
    let historyCalls = 0;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => {
      if (path.includes("/change-history") && historyCalls++ === 0)
        return Promise.resolve(new Response("private history detail", { status: 503 }));
      return defaultFetch(path, options);
    });
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Ver log de alterações" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível carregar o log de alterações");
    expect(screen.getByRole("alert")).not.toHaveTextContent("private history detail");
    fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
    expect(await screen.findByText("Nenhum evento de auditoria foi registrado para este produto.")).toBeInTheDocument();
  });

  it("prevents duplicate date submissions", async () => {
    const defaultFetch = api.fetch.getMockImplementation()!;
    let resolveDate!: (value: Response) => void;
    let dateCalls = 0;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => {
      if (path.endsWith("/dates") && options?.method === "PATCH") {
        dateCalls++;
        return new Promise<Response>((resolve) => { resolveDate = resolve; });
      }
      return defaultFetch(path, options);
    });
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Editar atividade" }));
    fireEvent.change(screen.getByLabelText("Início planejado"), { target: { value: "03/11/2026" } });
    fireEvent.change(screen.getByLabelText("Fim planejado"), { target: { value: "10/11/2026" } });
    fireEvent.change(screen.getByLabelText("Justificativa da alteração"),
      { target: { value: "Synthetic approved correction" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar datas" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Salvar datas" })).toBeDisabled());
    fireEvent.click(screen.getByRole("button", { name: "Salvar datas" }));
    expect(dateCalls).toBe(1);
    resolveDate(json({ activity: { ...activity, plannedStart: "2026-11-03",
      plannedEnd: "2026-11-10", version: 2 }, changed: true }));
    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("registradas no histórico"));
  });

  it("shows retry after load failure and safe conflict feedback", async () => {
    api.fetch.mockResolvedValueOnce(new Response("", { status: 503 }))
      .mockResolvedValueOnce(json({ stageDefinitions: definitions }));
    mount();
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível carregar o cronograma");
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
    fireEvent.click(await screen.findByRole("button", { name: "Adicionar disciplina" }));
    fireEvent.change(screen.getByLabelText("Nome da disciplina"), { target: { value: "Nova" } });
    fireEvent.change(screen.getByLabelText("Código da disciplina"), { target: { value: "N" } });
    api.fetch.mockResolvedValueOnce(json({ error: "private detail" }, 409));
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Este item foi alterado");
    expect(screen.getByRole("alert")).not.toHaveTextContent("private detail");
    expect(screen.getAllByRole("button", { name: "Atualizar dados" })).toHaveLength(2);
  });

  it("creates root activities with the default color, custom colors, and manual dates through the product route", async () => {
    const { container } = render(<ScheduleEditor workspace={workspace} product={product} userId={userId}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await waitFor(() => expect(container.querySelector(`[data-row-key="product:${product.id}"]`)).toBeInTheDocument());
    const productRow = container.querySelector<HTMLElement>(`[data-row-key="product:${product.id}"]`)!;
    fireEvent.click(within(productRow).getByRole("button", { name: "Adicionar atividade" }));
    expect(screen.getByText(/cor padr.*atividade de produto \(#8D9A89\)/i)).toBeInTheDocument();
    expect(screen.queryByText(/cor da etapa/i)).not.toBeInTheDocument();
    fireEvent.change(container.querySelector("#activity-color")!, { target: { value: "#123ABC" } });
    fireEvent.click(screen.getByRole("button", { name: /Restaurar cor padrão/ }));
    expect(container.querySelector<HTMLInputElement>("#activity-color")).toHaveValue("#8D9A89");
    expect(screen.queryByRole("button", { name: /Restaurar cor padrão/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Cancelar" }));
    expect(api.fetch.mock.calls.some(([path, options]) => String(path).endsWith("/root-activities") && options?.method === "POST"))
      .toBe(false);
    expect(readRecentCustomColors(userId)).toEqual([]);

    fireEvent.click(within(productRow).getByRole("button", { name: "Adicionar atividade" }));
    fireEvent.change(screen.getByLabelText("Nome da atividade"), { target: { value: "New root activity" } });
    fireEvent.change(container.querySelector("#activity-start")!, { target: { value: "11/11/2026" } });
    fireEvent.change(container.querySelector("#activity-end")!, { target: { value: "13/11/2026" } });
    fireEvent.change(container.querySelector("#activity-color")!, { target: { value: "#123ABC" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/products/${product.id}/root-activities`,
      expect.objectContaining({ method: "POST", body: JSON.stringify({ name: "New root activity", activityType: null,
        displayOrder: 0, notes: null, colorOverride: "#123ABC", planningMode: "manual",
        plannedStart: "2026-11-11", plannedEnd: "2026-11-13" }) })
    ));
    expect(readRecentCustomColors(userId)).toEqual(["#123ABC"]);
  });

  it("edits root overrides, saves root dates through the parentless route, and opens activity history", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    let current: Omit<typeof rootActivity, "colorOverride"> & { colorOverride: string | null } = rootActivity;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => {
      if (path.endsWith("/hierarchy")) return Promise.resolve(json({ hierarchy: { ...rootTree, rootActivities: [current] } }));
      if (path.endsWith("/calendar-impact")) return Promise.resolve(json({ calendarVersion: 0, impacts: [] }));
      if (path.endsWith(`/root-activities/${rootActivity.id}/dates`) && options?.method === "PATCH") {
        current = { ...current, plannedStart: "2026-11-12", plannedEnd: "2026-11-14", version: current.version + 1 };
        return Promise.resolve(json({ activity: current, changed: true }));
      }
      if (path.endsWith(`/root-activities/${rootActivity.id}`) && options?.method === "PATCH") {
        const input = JSON.parse(String(options.body)) as { colorOverride: string | null };
        current = { ...current, colorOverride: input.colorOverride, version: current.version + 1 };
        return Promise.resolve(json({ activity: current }));
      }
      if (path.includes("/change-history")) return Promise.resolve(json({ events: [], nextCursor: null }));
      if (path.endsWith("/targets")) return Promise.resolve(json({ targets: [] }));
      if (path.includes("/calendar?year=")) return Promise.resolve(json({ calendar: { version: 0, exceptions: [] } }));
      return Promise.resolve(json({ stageDefinitions: definitions }));
    });
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await waitFor(() => expect(container.querySelector(`[data-row-key="activity:${rootActivity.id}"]`)).toBeInTheDocument());
    const row = container.querySelector<HTMLElement>(`[data-row-key="activity:${rootActivity.id}"]`)!;
    fireEvent.click(within(row).getByRole("button", { name: "Editar atividade" }));
    expect(container.querySelector<HTMLInputElement>("#activity-color")).toHaveValue("#AA5577");
    fireEvent.click(screen.getByRole("button", { name: /Restaurar cor padrão/ }));
    fireEvent.click(screen.getByRole("button", { name: "Salvar dados" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/products/${product.id}/root-activities/${rootActivity.id}`,
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"colorOverride":null') })
    ));
    await waitFor(() => expect(container.querySelector(".timeline-bar.bar-activity")).toHaveStyle({ backgroundColor: "#8D9A89" }));

    const refreshedRow = container.querySelector<HTMLElement>(`[data-row-key="activity:${rootActivity.id}"]`)!;
    fireEvent.click(within(refreshedRow).getByRole("button", { name: "Editar atividade" }));
    fireEvent.change(container.querySelector("#date-start")!, { target: { value: "12/11/2026" } });
    fireEvent.change(container.querySelector("#date-end")!, { target: { value: "14/11/2026" } });
    fireEvent.change(container.querySelector("#date-reason")!, { target: { value: "Synthetic root date correction" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar datas" }));
    await waitFor(() => expect(api.fetch.mock.calls.some(([path, options]) =>
      String(path).endsWith(`/root-activities/${rootActivity.id}/dates`) && options?.method === "PATCH")).toBe(true));
    const rootDateCall = api.fetch.mock.calls.find(([path, options]) =>
      String(path).endsWith(`/root-activities/${rootActivity.id}/dates`) && options?.method === "PATCH");
    expect(JSON.parse(String(rootDateCall?.[1]?.body))).toMatchObject({ plannedStart: "2026-11-12",
      plannedEnd: "2026-11-14", reason: "Synthetic root date correction", version: 5 });

    const currentRow = container.querySelector<HTMLElement>(`[data-row-key="activity:${rootActivity.id}"]`)!;
    fireEvent.click(within(currentRow).getByRole("button", { name: `Histórico de datas: ${rootActivity.name}` }));
    expect(await screen.findByRole("heading", { name: /Synthetic root activity/ })).toBeInTheDocument();
    expect(api.fetch).toHaveBeenCalledWith(expect.stringContaining("/change-history?"), expect.anything());
    confirmation.mockRestore();
  });

  it("creates a root activity with a reviewed working-day plan", async () => {
    const original = api.fetch.getMockImplementation()!;
    const preview = { startDate: "2026-11-06", endDate: "2026-11-10", workingDays: 2,
      calendarVersion: 7, optionalDaysVerified: true, unverifiedOptionalYears: [], skippedDates: [] };
    api.fetch.mockImplementation((path: string, options?: RequestInit) => path.includes("working-day-preview")
      ? Promise.resolve(json({ preview })) : original(path, options));
    const { container } = render(<ScheduleEditor workspace={workspace} product={product}
      onBack={vi.fn()} onAccessLost={vi.fn()} />);
    await waitFor(() => expect(container.querySelector(`[data-row-key="product:${product.id}"]`)).toBeInTheDocument());
    fireEvent.click(within(container.querySelector(`[data-row-key="product:${product.id}"]`)!)
      .getByRole("button", { name: "Adicionar atividade" }));
    fireEvent.change(screen.getByLabelText("Nome da atividade"), { target: { value: "Root working activity" } });
    fireEvent.change(screen.getByLabelText("Modo de planejamento"), { target: { value: "working_days" } });
    fireEvent.change(container.querySelector("#activity-start")!, { target: { value: "06/11/2026" } });
    fireEvent.change(container.querySelector("#activity-working-days")!, { target: { value: "2" } });
    fireEvent.click(screen.getByRole("button", { name: /Calcular/ }));
    expect(await screen.findByText("10/11/2026")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/products/${product.id}/root-activities`,
      expect.objectContaining({ method: "POST", body: JSON.stringify({ name: "Root working activity", activityType: null,
        displayOrder: 0, notes: null, colorOverride: null, planningMode: "working_days",
        plannedStart: "2026-11-06", workingDays: 2, calendarVersion: 7 }) })
    ));
  });

  it("includes root working plans in the existing calendar impact preview", async () => {
    const plannedRoot = { ...rootActivity, plannedStart: "2026-11-09", plannedEnd: "2026-11-10",
      version: 3, planningMode: "working_days" as const, workingDayDuration: 2, planningCalendarVersion: 1 };
    const rootImpact: ActivityCalendarImpact = { ...dateImpact, activityId: plannedRoot.id,
      disciplineId: null, stageId: null, activityVersion: 3, workingDays: 2,
      savedCalendarVersion: 1, currentCalendarVersion: 2,
      currentStartDate: plannedRoot.plannedStart, currentEndDate: plannedRoot.plannedEnd };
    setupImpacts([rootImpact], { ...rootTree, rootActivities: [plannedRoot] });
    const fallback = api.fetch.getMockImplementation()!;
    api.fetch.mockImplementation((path: string, options?: RequestInit) => path.endsWith("/calendar-impact/apply")
      ? Promise.resolve(json({ changedCount: 1 })) : fallback(path, options));
    mount("editor");
    fireEvent.click(await screen.findByRole("button", { name: "Revisar impactos" }));
    const panel = screen.getByRole("dialog", { name: /impactos do calend/i });
    const rootSelection = within(panel).getByRole("checkbox", { name: plannedRoot.name });
    expect(rootSelection).toBeInTheDocument();
    expect(within(panel).queryByText(/desatualizada/)).not.toBeInTheDocument();
    fireEvent.click(rootSelection);
    fireEvent.change(within(panel).getByLabelText(/justificativa/i), { target: { value: "Synthetic root reschedule" } });
    fireEvent.click(within(panel).getByRole("button", { name: "Reprogramar selecionadas" }));
    const confirmation = await screen.findByRole("alertdialog", { name: /Confirmar reprograma/i });
    fireEvent.click(within(confirmation).getByRole("button", { name: /Confirmar reprograma/i }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/products/${product.id}/calendar-impact/apply`,
      expect.objectContaining({ method: "POST", body: JSON.stringify({ calendarVersion: 2,
        reason: "Synthetic root reschedule", selections: [{ activityId: plannedRoot.id, version: 3 }] }) })
    ));
  });

  it("reports missing hierarchy and rechecks access loss", async () => {
    api.fetch.mockResolvedValueOnce(json({}, 404)).mockResolvedValueOnce(json({ stageDefinitions: definitions }));
    const onAccessLost = mount();
    expect(await screen.findByRole("alert")).toHaveTextContent("Cronograma não encontrado");
    expect(onAccessLost).not.toHaveBeenCalled();
  });

  it("does not render hierarchy after unauthorized API access", async () => {
    api.fetch.mockResolvedValueOnce(json({}, 401)).mockResolvedValueOnce(json({ stageDefinitions: definitions }));
    const onAccessLost = mount();
    await waitFor(() => expect(onAccessLost).toHaveBeenCalledOnce());
    expect(screen.queryByText("Synthetic activity")).not.toBeInTheDocument();
  });
});

describe("civil dates", () => {
  it("formats without timezone conversion and rejects invalid Brazilian dates", () => {
    expect(formatCivilDate("2026-11-01")).toBe("01/11/2026");
    expect(parseBrazilianDate("01/11/2026")).toBe("2026-11-01");
    expect(parseBrazilianDate("29/02/2028")).toBe("2028-02-29");
    expect(parseBrazilianDate("29/02/2026")).toBeNull();
    expect(parseBrazilianDate("2026-11-01")).toBeNull();
  });
});
