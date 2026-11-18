import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ProductChangeHistoryDialog } from "../src/ProductChangeHistoryDialog";

const auth = vi.hoisted(() => ({ fetch: vi.fn() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: auth.fetch }));

const base = "/api/workspaces/workspace/products/product";
const activityEvent = {
  id: "activity-date:00000000-0000-4000-8000-000000000001",
  occurredAt: "2026-11-09T01:00:00.000Z", actorId: "actor", actorName: "Synthetic editor",
  eventType: "activity_dates_changed", item: { kind: "activity", id: "activity-1",
    name: "Synthetic activity", hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage" } },
  justification: "Synthetic date correction", before: { plannedStart: "2026-11-01", plannedEnd: "2026-11-08" },
  after: { plannedStart: "2026-11-03", plannedEnd: "2026-11-10" }, affectedItems: []
};
const productEvent = {
  id: "product:00000000-0000-4000-8000-000000000002", occurredAt: "2026-11-08T12:00:00.000Z",
  actorId: "actor", actorName: null, eventType: "product_created",
  item: { kind: "product", id: "product", name: "Synthetic product" },
  justification: null, before: null, after: null, affectedItems: []
};
const movementEvent = {
  id: "hierarchy-movement:00000000-0000-4000-8000-000000000003",
  occurredAt: "2026-11-10T13:00:00.000Z", actorId: "actor", actorName: "Synthetic editor",
  eventType: "hierarchy_moved", item: { kind: "activity", id: "activity-1",
    name: "Synthetic activity", hierarchy: { scope: "product_root" } },
  justification: null,
  before: { parent: { scope: "stage", discipline: "Synthetic discipline", stage: "Synthetic stage" }, position: 3 },
  after: { parent: { scope: "product_root", discipline: null, stage: null }, position: 1 }, affectedItems: []
};
function json(value: unknown, status = 200) { return new Response(JSON.stringify(value), { status }); }
function mount(activity?: { id: string; name: string }, onClose = vi.fn(), onAccessLost = vi.fn()) {
  return { ...render(<ProductChangeHistoryDialog base={base} activity={activity}
    onClose={onClose} onAccessLost={onAccessLost} />), onClose, onAccessLost };
}

beforeEach(() => {
  vi.clearAllMocks();
  auth.fetch.mockResolvedValue(json({ events: [], nextCursor: null }));
});

describe("ProductChangeHistoryDialog", () => {
  it("filters only event types supplied by the product history feed", async () => {
    auth.fetch.mockResolvedValue(json({ events: [activityEvent, productEvent], nextCursor: null }));
    mount();
    const dialog = await screen.findByRole("dialog", { name: "Log de alterações do produto" });
    expect(within(dialog).getByText("Synthetic activity")).toBeInTheDocument();
    expect(within(dialog).getByText("Synthetic product")).toBeInTheDocument();
    fireEvent.change(within(dialog).getByLabelText("Filtrar por tipo de evento"), {
      target: { value: "activity_dates_changed" }
    });
    expect(within(dialog).getByText("Synthetic activity")).toBeInTheDocument();
    expect(within(dialog).queryByText("Synthetic product")).not.toBeInTheDocument();
    expect(within(dialog).getByText(/não representa revisões formais/)).toBeInTheDocument();
    expect(within(dialog).getByText(/Informações anteriores à cobertura de auditoria não são reconstruídas/)).toBeInTheDocument();
  });

  it("shows movement actor, time, item type, parent hierarchy and one-based positions", async () => {
    auth.fetch.mockResolvedValue(json({ events: [movementEvent, activityEvent], nextCursor: null }));
    mount();
    const dialog = await screen.findByRole("dialog");
    const movementCard = within(dialog).getByText("Atividade movida").closest("li")!;
    expect(within(movementCard).getByText("Synthetic activity")).toBeInTheDocument();
    expect(within(movementCard).getByText("Synthetic editor")).toBeInTheDocument();
    expect(movementCard.querySelector("time")).toHaveAttribute("dateTime", movementEvent.occurredAt);
    fireEvent.click(within(movementCard).getByText("Ver antes e depois"));
    const comparison = movementCard.querySelector(".product-history__movement-comparison") as HTMLElement;
    expect(within(comparison).getByText("Atividades de Produto")).toBeInTheDocument();
    expect(comparison).toHaveTextContent("Local anterior");
    expect(comparison).toHaveTextContent("Synthetic discipline › Synthetic stage");
    expect(comparison).toHaveTextContent(/Posi.+anterior/);
    expect(comparison).toHaveTextContent("3");
    expect(comparison).toHaveTextContent("Nova posição");
    expect(comparison).toHaveTextContent("1");
    fireEvent.change(within(dialog).getByLabelText("Filtrar por tipo de evento"), {
      target: { value: "hierarchy_moved" }
    });
    expect(within(dialog).getByText("Atividade movida")).toBeInTheDocument();
    expect([...dialog.querySelectorAll(".product-history__event-type")].map((item) => item.textContent))
      .toEqual(["Atividade movida"]);
  });

  it("renders audited stage date events with the stage-specific event label", async () => {
    const stageDateEvent = { ...activityEvent, id: "stage-date:00000000-0000-4000-8000-000000000004",
      actorName: null,
      eventType: "stage_dates_changed", item: { kind: "stage", id: "stage-1",
        name: "Synthetic stage", hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage" } },
      before: { plannedStart: null, plannedEnd: null },
      after: { plannedStart: "2026-11-03", plannedEnd: null } };
    auth.fetch.mockResolvedValue(json({ events: [stageDateEvent], nextCursor: null }));
    mount();
    const dialog = await screen.findByRole("dialog");
    const stageCard = within(dialog).getByText("Synthetic stage").closest("li")!;
    expect(within(stageCard).getByText("Datas da etapa alteradas")).toBeInTheDocument();
    expect(stageCard).toHaveTextContent("Usuário (ID: actor)");
    expect(stageCard).toHaveTextContent("Synthetic date correction");
    expect(stageCard.querySelector("time")).toHaveAttribute("dateTime", stageDateEvent.occurredAt);
    expect(within(dialog).getByRole("option", { name: "Datas da etapa alteradas" })).toHaveValue("stage_dates_changed");
    fireEvent.click(within(stageCard).getByText("Ver antes e depois"));
    const comparison = stageCard.querySelector(".product-history__stage-date-comparison")!;
    expect(comparison).toHaveTextContent("Sem data");
    expect(comparison).toHaveTextContent("03/11/2026");
    expect(comparison).toHaveTextContent("Início");
    expect(comparison).toHaveTextContent("Fim");
  });

  it("renders stage moves and discipline reordering as single hierarchy events", async () => {
    const stageMove = { ...movementEvent, id: "hierarchy-movement:stage", item: { kind: "stage", id: "stage-1",
      name: "Synthetic stage", hierarchy: { discipline: "New discipline", stage: "Synthetic stage" } },
      before: { parent: { scope: "stage", discipline: "Old discipline", stage: "Synthetic stage" }, position: 2 },
      after: { parent: { scope: "stage", discipline: "New discipline", stage: "Synthetic stage" }, position: 1 } };
    const disciplineMove = { ...movementEvent, id: "hierarchy-movement:discipline", item: { kind: "discipline",
      id: "discipline-1", name: "Synthetic discipline", hierarchy: { discipline: "Synthetic discipline" } },
      before: { parent: { scope: "product", discipline: null, stage: null }, position: 2 },
      after: { parent: { scope: "product", discipline: null, stage: null }, position: 1 } };
    auth.fetch.mockResolvedValue(json({ events: [stageMove, disciplineMove], nextCursor: null }));
    mount();
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByText("Etapa movida")).toBeInTheDocument();
    expect(within(dialog).getByText("Disciplina reordenada")).toBeInTheDocument();
    for (const label of ["Etapa movida", "Disciplina reordenada"]) {
      const card = within(dialog).getByText(label).closest("li")!;
      fireEvent.click(within(card).getByText("Ver antes e depois"));
      const comparison = card.querySelector(".product-history__movement-comparison")!;
      expect(comparison).toHaveTextContent("Posição anterior");
      expect(comparison).toHaveTextContent("Nova posição");
      expect(comparison).toHaveTextContent("2");
      expect(comparison).toHaveTextContent("1");
    }
    const stageCard = within(dialog).getByText("Etapa movida").closest("li")!;
    expect(stageCard.querySelector(".product-history__movement-comparison"))
      .toHaveTextContent("Old discipline › Synthetic stage");
    expect(stageCard.querySelector(".product-history__movement-comparison"))
      .toHaveTextContent("New discipline › Synthetic stage");
    expect(dialog.querySelectorAll(".product-history__event")).toHaveLength(2);
  });

  it("loads additional events by the returned cursor", async () => {
    auth.fetch.mockResolvedValueOnce(json({ events: [productEvent], nextCursor: "opaque-next-cursor" }))
      .mockResolvedValueOnce(json({ events: [{ ...activityEvent, id: "activity-date:older" }], nextCursor: null }));
    mount();
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByText("Synthetic product")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Carregar mais" }));
    expect(await within(dialog).findByText("Synthetic activity")).toBeInTheDocument();
    const secondRequest = auth.fetch.mock.calls[1]?.[0] as string;
    expect(new URL(secondRequest, "https://example.test").searchParams.get("cursor")).toBe("opaque-next-cursor");
  });

  it("expands available hierarchy, justification, and before/after civil dates", async () => {
    auth.fetch.mockResolvedValue(json({ events: [activityEvent], nextCursor: null }));
    mount();
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByText("Synthetic discipline › Synthetic stage")).toBeInTheDocument();
    expect(within(dialog).getByText(/Synthetic date correction/)).toBeInTheDocument();
    fireEvent.click(within(dialog).getByText("Ver antes e depois"));
    const comparison = dialog.querySelector(".product-history__value-columns");
    expect(comparison).toHaveTextContent("Antes");
    expect(comparison).toHaveTextContent("01/11/2026");
    expect(comparison).toHaveTextContent("08/11/2026");
    expect(comparison).toHaveTextContent("03/11/2026");
    expect(comparison).toHaveTextContent("10/11/2026");
    expect(dialog.querySelector("time")).toHaveAttribute("dateTime", activityEvent.occurredAt);
    expect(dialog.querySelector("time")).toHaveTextContent(/08\/11\/2026.*22:00/);
  });

  it("keeps the selected activity history available for grouped batch events", async () => {
    const batch = { ...activityEvent, id: "calendar-reschedule:batch", eventType: "calendar_rescheduled",
      item: { kind: "calendar_reschedule", id: "batch", name: null }, justification: "Synthetic batch reason",
      affectedItems: [{ kind: "activity", id: "activity-1", name: "Synthetic activity",
        hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage" } }],
      before: { activities: [{ activityId: "activity-1", plannedStart: "2026-11-01", plannedEnd: "2026-11-08" }] },
      after: { activities: [{ activityId: "activity-1", plannedStart: "2026-11-02", plannedEnd: "2026-11-09" }] } };
    const unrelated = { ...productEvent, id: "other", eventType: "activity_dates_changed",
      item: { kind: "activity", id: "activity-2", name: "Unrelated activity" } };
    auth.fetch.mockResolvedValue(json({ events: [batch, unrelated], nextCursor: null }));
    mount({ id: "activity-1", name: "Synthetic activity" });
    const dialog = await screen.findByRole("dialog", { name: "Histórico de alterações: Synthetic activity" });
    expect(within(dialog).getByText("Synthetic batch reason")).toBeInTheDocument();
    expect(within(dialog).queryByText("Unrelated activity")).not.toBeInTheDocument();
    fireEvent.click(within(dialog).getByText("Ver antes e depois"));
    const comparison = dialog.querySelector(".product-history__date-comparison");
    expect(comparison).toHaveTextContent("01/11/2026 a 08/11/2026");
    expect(comparison).toHaveTextContent("02/11/2026 a 09/11/2026");
  });

  it("includes direct activity moves and ancestor stage moves in activity-specific history", async () => {
    const stageMove = { ...movementEvent, id: "hierarchy-movement:stage",
      item: { kind: "stage", id: "stage-1", name: "Synthetic stage",
        hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage" } },
      affectedItems: [{ kind: "activity", id: "activity-1", name: "Synthetic activity",
        hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage" } }] };
    const unrelatedMove = { ...movementEvent, id: "hierarchy-movement:other",
      item: { kind: "activity", id: "activity-2", name: "Unrelated activity" } };
    auth.fetch.mockResolvedValue(json({ events: [stageMove, movementEvent, unrelatedMove], nextCursor: null }));
    mount({ id: "activity-1", name: "Synthetic activity" });
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByText("Etapa movida")).toBeInTheDocument();
    expect(within(dialog).getByText("Atividade movida")).toBeInTheDocument();
    expect(within(dialog).queryByText("Unrelated activity")).not.toBeInTheDocument();
  });

  it("shows a safe retryable error and supports keyboard dismissal", async () => {
    const onClose = vi.fn();
    auth.fetch.mockResolvedValueOnce(new Response("sensitive provider detail", { status: 503 }))
      .mockResolvedValueOnce(json({ events: [], nextCursor: null }));
    mount(undefined, onClose);
    const dialog = await screen.findByRole("dialog");
    const alert = await within(dialog).findByRole("alert");
    expect(alert).toHaveTextContent("Não foi possível carregar o log de alterações");
    expect(alert).not.toHaveTextContent("sensitive provider detail");
    fireEvent.click(within(alert).getByRole("button", { name: "Tentar novamente" }));
    await waitFor(() => expect(within(dialog).queryByRole("alert")).not.toBeInTheDocument());
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(onClose).toHaveBeenCalledOnce();
  });

  it("renders generic details in one operation group and filters by represented specialized type", async () => {
    const operationId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    const grouped = {
      id: `operation:${operationId}`, occurredAt: "2026-11-11T12:30:00.000Z",
      actorId: "actor", actorName: "Synthetic editor", eventType: "living_schedule_operation",
      item: null, justification: "Synthetic grouped schedule reason", before: null, after: null,
      affectedItems: [{ kind: "activity", id: "activity-1", name: null }], operationId,
      operationType: "schedule_metadata_updated", reversalOfOperationId: null,
      sourceEventTypes: ["living_schedule_operation", "activity_dates_changed"],
      details: [
        { eventId: "activity-date:11111111-1111-4111-8111-111111111111", source: "specialized",
          eventType: "activity_dates_changed", item: { kind: "activity", id: "activity-1",
            name: "Synthetic activity", hierarchy: { discipline: "Recorded discipline", stage: "Recorded stage" } },
          justification: "Synthetic grouped schedule reason",
          before: { plannedStart: "2026-11-01", plannedEnd: "2026-11-08" },
          after: { plannedStart: "2026-11-03", plannedEnd: "2026-11-10" }, affectedItems: [] },
        { eventId: "921", source: "living_schedule", eventType: "schedule_operation_detail",
          entityType: "stage_activities", entityId: "activity-1", changeType: "stage_activities_updated",
          item: { kind: "activity", id: "activity-1", name: null },
          parentBefore: { disciplineId: "recorded-discipline-id", stageId: "recorded-stage-id" },
          parentAfter: { disciplineId: "recorded-discipline-id", stageId: "recorded-stage-id" },
          before: { name: "Old recorded name" }, after: { name: "New recorded name" } }
      ]
    };
    auth.fetch.mockResolvedValue(json({ events: [grouped], nextCursor: null }));
    mount();
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByText("Synthetic editor")).toBeInTheDocument();
    expect(within(dialog).getByText("Synthetic grouped schedule reason")).toBeInTheDocument();
    expect(within(dialog).getAllByText("Dados do cronograma alterados")).toHaveLength(2);
    fireEvent.change(within(dialog).getByLabelText("Filtrar por tipo de evento"), {
      target: { value: "activity_dates_changed" }
    });
    const detailRow = within(dialog).getByText("Synthetic activity").closest("li") as HTMLElement;
    const card = detailRow.closest(".product-history__event") as HTMLElement;
    fireEvent.click(within(card).getByText("Ver alterações da operação (2)"));
    expect(card).toHaveTextContent("01/11/2026");
    expect(card).toHaveTextContent("10/11/2026");
    expect(card).toHaveTextContent("Old recorded name");
    expect(card).toHaveTextContent("New recorded name");
    expect(card).toHaveTextContent("Identificador da disciplina: recorded-discipline-id");
    expect(card).toHaveTextContent("Identificador da etapa: recorded-stage-id");
    expect(card).not.toHaveTextContent("stage_activities");
  });

  it("shows reversal lineage without adding reversal actions and tolerates missing historical labels", async () => {
    const operationId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    const originalId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    const reversal = {
      id: `operation:${operationId}`, occurredAt: "2026-11-12T12:30:00.000Z",
      actorId: "actor", actorName: null, eventType: "living_schedule_operation",
      item: null, justification: "Synthetic reversal reason", before: null, after: null,
      affectedItems: [{ kind: "activity", id: "deleted-activity-id", name: null }],
      operationId, operationType: "calendar_reschedule_reversed", reversalOfOperationId: originalId,
      sourceEventTypes: ["living_schedule_operation", "calendar_reschedule_reversed"],
      details: [
        { eventId: "calendar-reversal:ffffffff-ffff-4fff-8fff-ffffffffffff", source: "specialized",
          eventType: "calendar_reschedule_reversed",
          item: { kind: "calendar_reschedule_reversal", id: "reversal-batch", name: null },
          justification: "Synthetic reversal reason",
          before: { originalOperationId: originalId, activities: [{ activityId: "deleted-activity-id",
            plannedStart: "2026-11-01", plannedEnd: "2026-11-07" }] },
          after: { originalOperationId: originalId, activities: [{ activityId: "deleted-activity-id",
            plannedStart: "2026-11-02", plannedEnd: "2026-11-08" }] },
          affectedItems: [{ kind: "activity", id: "deleted-activity-id", name: null }] },
        { eventId: "933", source: "living_schedule", eventType: "schedule_operation_detail",
          item: { kind: "activity", id: "deleted-activity-id", name: null },
          entityType: "stage_activities", entityId: "deleted-activity-id",
          before: { planned_start: "2026-11-01" }, after: { planned_start: "2026-11-02" } }
      ]
    };
    auth.fetch.mockResolvedValue(json({ events: [reversal], nextCursor: null }));
    mount();
    const dialog = await screen.findByRole("dialog");
    const card = dialog.querySelector(".product-history__event") as HTMLElement;
    expect(card).toHaveTextContent(originalId);
    expect(card).toHaveTextContent("Atividade · deleted-activity-id");
    expect(card).toHaveTextContent("Nome indisponível");
    fireEvent.click(within(card).getByText("Ver alterações da operação (2)"));
    expect(card).toHaveTextContent("01/11/2026 a 07/11/2026");
    expect(card).toHaveTextContent("02/11/2026 a 08/11/2026");
    expect(within(card).queryByRole("button", { name: /reverter/i })).not.toBeInTheDocument();
  });
});
