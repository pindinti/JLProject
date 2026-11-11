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
    expect(within(dialog).getByText(/Não há eventos para edição cadastral/)).toBeInTheDocument();
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
});
