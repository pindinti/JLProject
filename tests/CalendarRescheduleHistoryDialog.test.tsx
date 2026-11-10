import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { CalendarRescheduleHistoryDialog } from "../src/CalendarRescheduleHistoryDialog";

const api = vi.hoisted(() => ({ fetch: vi.fn() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: api.fetch }));

const base = "/api/workspaces/workspace-id/products/product-id";
const operationId = "a1111111-1111-4111-8111-111111111111";
const operation = {
  operationId, changedAt: "2026-11-10T15:30:00.000Z", actorName: "Synthetic Admin",
  reason: "Synthetic original justification", status: "eligible", reversal: null,
  activities: [{ activityId: "b1111111-1111-4111-8111-111111111111", name: "Synthetic activity",
    previousStart: "2026-11-01", previousEnd: "2026-11-03", newStart: "2026-11-01", newEnd: "2026-11-04",
    currentStart: "2026-11-01", currentEnd: "2026-11-04" }]
};
const hierarchy = { disciplines: [{ name: "Synthetic discipline", stages: [{
  displayName: "Synthetic stage", activities: [{ id: operation.activities[0].activityId }]
}] }] };

function json(value: unknown, status = 200) { return new Response(JSON.stringify(value), { status }); }
function mount(canEdit = true, onAccessLost = vi.fn(), onReversed = vi.fn(async () => undefined),
  currentHierarchy: typeof hierarchy | null = hierarchy) {
  const onClose = vi.fn();
  render(<CalendarRescheduleHistoryDialog base={base} hierarchy={currentHierarchy} canEdit={canEdit} onClose={onClose}
    onAccessLost={onAccessLost} onReversed={onReversed} />);
  return { onClose, onAccessLost, onReversed };
}

beforeEach(() => {
  vi.clearAllMocks();
  api.fetch.mockImplementation((path: string) => Promise.resolve(path.endsWith("/calendar-reschedules/history")
    ? json({ operations: [operation] }) : json({ reversedCount: 1 })));
});

describe("calendar reschedule history dialog", () => {
  it("shows localized operation details and activity before/after dates", async () => {
    mount();
    const dialog = await screen.findByRole("dialog", { name: "Histórico de reprogramações" });
    expect(within(dialog).getByText("Responsável: Synthetic Admin")).toBeInTheDocument();
    expect(within(dialog).getByText("Synthetic original justification")).toBeInTheDocument();
    expect(within(dialog).getByText("Disponível para reversão")).toBeInTheDocument();
    expect(within(dialog).getByText("1 atividade afetada")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByText("Ver atividades"));
    expect(within(dialog).getByText("Synthetic discipline › Synthetic stage › Synthetic activity")).toBeInTheDocument();
    expect(within(dialog).getByText("Antes: 01/11/2026 a 03/11/2026")).toBeInTheDocument();
    expect(within(dialog).getByText("Depois: 01/11/2026 a 04/11/2026")).toBeInTheDocument();
  });

  it("clears a whole-operation selection without submitting or changing activity details", async () => {
    mount();
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByText("A seleção reverte todas as atividades da operação em conjunto.")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByLabelText("Selecionar para reversão"));
    expect(within(dialog).getByLabelText("Selecionar para reversão")).toBeChecked();
    fireEvent.click(within(dialog).getByRole("button", { name: "Limpar seleção" }));
    expect(within(dialog).getByLabelText("Selecionar para reversão")).not.toBeChecked();
    expect(within(dialog).getByRole("button", { name: "Reverter operação" })).toBeDisabled();
    expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/reverse"))).toHaveLength(0);
  });

  it("does not invent hierarchy labels when the activity is absent from the current tree", async () => {
    mount(true, vi.fn(), vi.fn(async () => undefined), null);
    const dialog = await screen.findByRole("dialog");
    fireEvent.click(within(dialog).getByText("Ver atividades"));
    expect(within(dialog).getByText("Synthetic activity")).toBeInTheDocument();
    expect(within(dialog).getByText("Hierarquia atual indisponível")).toBeInTheDocument();
    expect(within(dialog).queryByText(/Synthetic discipline/)).not.toBeInTheDocument();
  });

  it("distinguishes reversed and conflicting operations while keeping only eligible rows selectable", async () => {
    api.fetch.mockResolvedValueOnce(json({ operations: [
      operation,
      { ...operation, operationId: "c1111111-1111-4111-8111-111111111111", status: "already_reversed",
        reversal: { changedAt: "2026-11-10T16:00:00.000Z", actorName: "Synthetic Editor", reason: "Synthetic reversal" } },
      { ...operation, operationId: "d1111111-1111-4111-8111-111111111111", status: "conflict" }
    ] }));
    mount();
    const dialog = await screen.findByRole("dialog", { name: "Histórico de reprogramações" });
    expect(within(dialog).getByText("Já revertida")).toBeInTheDocument();
    expect(within(dialog).getByText("Conflito: atividade alterada depois da operação")).toBeInTheDocument();
    expect(within(dialog).getAllByLabelText("Selecionar para reversão")).toHaveLength(1);
    expect(within(dialog).getByText("Revertida em 10/11/2026, 13:00 por Synthetic Editor.")).toBeInTheDocument();
  });

  it("requires selection, justification, and separate confirmation before calling the controlled endpoint", async () => {
    const { onReversed } = mount();
    const dialog = await screen.findByRole("dialog", { name: "Histórico de reprogramações" });
    fireEvent.click(within(dialog).getByLabelText("Selecionar para reversão"));
    const reason = within(dialog).getByLabelText("Justificativa da reversão");
    fireEvent.change(reason, { target: { value: "Synthetic audited reversal reason" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Reverter operação" }));
    expect(screen.getByRole("alertdialog", { name: "Confirmar reversão" })).toBeInTheDocument();
    expect(api.fetch.mock.calls.filter(([path, init]) => String(path).includes("/reverse") &&
      (init as RequestInit | undefined)?.method === "POST")).toHaveLength(0);
    fireEvent.click(screen.getByRole("button", { name: "Confirmar reversão" }));
    await waitFor(() => expect(onReversed).toHaveBeenCalledOnce());
    const call = api.fetch.mock.calls.find(([path, init]) => String(path).endsWith(`/calendar-reschedules/${operationId}/reverse`) &&
      (init as RequestInit | undefined)?.method === "POST");
    expect(call).toBeDefined();
    expect(JSON.parse((call?.[1] as RequestInit).body as string)).toEqual({ reason: "Synthetic audited reversal reason" });
    expect(JSON.stringify(call?.[1])).not.toMatch(/previousStart|newStart|previousEnd|newEnd/);
    expect(await screen.findByText(/Reversão concluída para 1 atividade/)).toBeInTheDocument();
  });

  it("keeps viewers read-only", async () => {
    mount(false);
    const dialog = await screen.findByRole("dialog", { name: "Histórico de reprogramações" });
    expect(within(dialog).getByText("Synthetic original justification")).toBeInTheDocument();
    expect(within(dialog).queryByLabelText("Selecionar para reversão")).not.toBeInTheDocument();
    expect(within(dialog).queryByLabelText("Justificativa da reversão")).not.toBeInTheDocument();
    expect(within(dialog).getByText("Seu perfil pode consultar este histórico, mas não pode reverter operações.")).toBeInTheDocument();
  });

  it("reports an atomic stale conflict without refreshing the schedule", async () => {
    const onReversed = vi.fn(async () => undefined);
    api.fetch.mockImplementation((path: string) => Promise.resolve(
      String(path).endsWith("/reverse") ? json({ code: "activity_changed" }, 409) : json({ operations: [operation] })
    ));
    mount(true, vi.fn(), onReversed);
    const dialog = await screen.findByRole("dialog", { name: "Histórico de reprogramações" });
    fireEvent.click(within(dialog).getByLabelText("Selecionar para reversão"));
    fireEvent.change(within(dialog).getByLabelText("Justificativa da reversão"),
      { target: { value: "Synthetic audited reversal reason" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Reverter operação" }));
    fireEvent.click(screen.getByRole("button", { name: "Confirmar reversão" }));
    expect(await within(dialog).findByText(/Uma ou mais atividades mudaram depois desta operação/)).toBeInTheDocument();
    expect(onReversed).not.toHaveBeenCalled();
    expect(api.fetch.mock.calls.filter(([path]) => String(path).endsWith("/calendar-reschedules/history"))).toHaveLength(1);
  });

  it("returns authorization loss to the application and presents retryable load errors", async () => {
    const onAccessLost = vi.fn();
    api.fetch.mockResolvedValueOnce(json({}, 403));
    mount(true, onAccessLost);
    await waitFor(() => expect(onAccessLost).toHaveBeenCalledOnce());
    cleanup();

    api.fetch.mockResolvedValueOnce(json({}, 503)).mockResolvedValueOnce(json({ operations: [] }));
    const second = mount(false);
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível carregar o histórico de reprogramações");
    fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
    expect(await screen.findByText("Nenhuma reprogramação de calendário foi registrada neste produto.")).toBeInTheDocument();
    expect(second.onAccessLost).not.toHaveBeenCalled();
  });
});
