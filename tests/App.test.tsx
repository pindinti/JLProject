import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "../src/App";

const auth = vi.hoisted(() => ({
  getSession: vi.fn(), signIn: vi.fn(), signOut: vi.fn(),
  requestPasswordReset: vi.fn(), resetPassword: vi.fn(),
  checkWorkspaceAccess: vi.fn(), listMyWorkspaces: vi.fn(), authenticatedFetch: vi.fn(),
  sendEmailVerificationCode: vi.fn(), verifyEmailCode: vi.fn()
}));

vi.mock("../src/auth", () => ({
  authClient: {
    getSession: auth.getSession,
    signIn: { email: auth.signIn },
    signOut: auth.signOut,
    requestPasswordReset: auth.requestPasswordReset,
    resetPassword: auth.resetPassword
  },
  checkWorkspaceAccess: auth.checkWorkspaceAccess,
  listMyWorkspaces: auth.listMyWorkspaces,
  authenticatedFetch: auth.authenticatedFetch,
  sendEmailVerificationCode: auth.sendEmailVerificationCode,
  verifyEmailCode: auth.verifyEmailCode
}));

beforeEach(() => {
  vi.clearAllMocks();
  window.history.replaceState(null, "", "/");
  auth.getSession.mockResolvedValue({ data: null, error: null });
  auth.signIn.mockResolvedValue({ data: {}, error: null });
  auth.signOut.mockResolvedValue({ data: {}, error: null });
  auth.requestPasswordReset.mockResolvedValue({ data: {}, error: null });
  auth.resetPassword.mockResolvedValue({ data: {}, error: null });
  auth.checkWorkspaceAccess.mockResolvedValue("pending");
  auth.listMyWorkspaces.mockResolvedValue([]);
  auth.authenticatedFetch.mockResolvedValue(new Response(JSON.stringify({ memberships: [] }), { status: 200 }));
  auth.sendEmailVerificationCode.mockResolvedValue(true);
  auth.verifyEmailCode.mockResolvedValue(true);
});

describe("administration UI", () => {
  const workspace = { id: "e97c159e-3f7b-4e27-8b1e-38036bf47a3f", name: "JLProject", role: "admin" };
  const member = { id: "e3aa998a-a2c3-4376-9105-90af0d1dbfe3", name: "Test User", email: "test@example.com", role: "admin", active: true };

  beforeEach(() => {
    auth.getSession.mockResolvedValue({ data: { session: { token: "valid-token" } }, error: null });
    auth.checkWorkspaceAccess.mockResolvedValue("authorized");
    auth.listMyWorkspaces.mockResolvedValue([workspace]);
    auth.authenticatedFetch.mockImplementation((path: string) => Promise.resolve(new Response(JSON.stringify(
      path.endsWith("/memberships") ? { memberships: [member] } : { products: [] }
    ), { status: 200 })));
  });

  it("loads the admin page and confirms a sensitive status change", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<App />);
    expect(await screen.findByRole("heading", { name: "Produtos" })).toBeInTheDocument();
    fireEvent.click(await screen.findByRole("button", { name: "Configurações" }));
    expect(await screen.findByRole("heading", { name: "Usuários" })).toBeInTheDocument();
    expect(screen.getByText("Test User")).toBeInTheDocument();
    auth.authenticatedFetch.mockResolvedValueOnce(new Response(JSON.stringify({ status: "updated" }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ memberships: [member] }), { status: 200 }));
    fireEvent.click(screen.getByRole("button", { name: "Desativar" }));
    await waitFor(() => expect(confirmation).toHaveBeenCalledWith("Desativar o acesso de Test User?"));
    await waitFor(() => expect(auth.authenticatedFetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/memberships/${member.id}`,
      expect.objectContaining({ method: "PATCH", body: JSON.stringify({ active: false }) })
    ));
    confirmation.mockRestore();
  });

  it("adds a user with editor as the default role and shows setup guidance", async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Configurações" }));
    await screen.findByText("Test User");
    fireEvent.change(screen.getByLabelText("E-mail do novo usuário"), { target: { value: "new@example.com" } });
    auth.authenticatedFetch.mockResolvedValueOnce(new Response(JSON.stringify({ status: "created" }), { status: 201 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ memberships: [member] }), { status: 200 }));
    fireEvent.click(screen.getByRole("button", { name: "Adicionar usuário" }));
    await waitFor(() => expect(auth.authenticatedFetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/memberships`,
      expect.objectContaining({ method: "POST", body: JSON.stringify({ email: "new@example.com", role: "editor" }) })
    ));
    expect(await screen.findByText(/Esqueci minha senha/)).toBeInTheDocument();
  });

  it("hides administration from non-admins and denies a direct route", async () => {
    auth.listMyWorkspaces.mockResolvedValue([{ ...workspace, role: "viewer" }]);
    window.history.replaceState(null, "", "/administracao");
    render(<App />);
    expect(await screen.findByRole("heading", { name: "Acesso não autorizado" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Usuários" })).not.toBeInTheDocument();
    expect(auth.authenticatedFetch).not.toHaveBeenCalled();
  });

  it("shows settings to non-admins without exposing user administration", async () => {
    auth.listMyWorkspaces.mockResolvedValue([{ ...workspace, role: "viewer" }]);
    window.history.replaceState(null, "", "/configuracoes");
    render(<App />);
    expect(await screen.findByRole("heading", { name: "Configurações" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Meu perfil" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Notificações" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Usuários" })).not.toBeInTheDocument();
    expect(auth.authenticatedFetch).not.toHaveBeenCalledWith(expect.stringContaining("memberships"));
  });

  it("replaces production user provisioning form with operator guidance", async () => {
    vi.stubEnv("DEV", false);
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Configurações" }));
    expect(await screen.findByText(/inclusão de usuários não está disponível nesta interface de produção/i)).toBeInTheDocument();
    expect(screen.queryByLabelText("E-mail do novo usuário")).not.toBeInTheDocument();
    vi.unstubAllEnvs();
  });

  it("confirms a role change and leaves canceled changes untouched", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(false);
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Configurações" }));
    await screen.findByText("Test User");
    fireEvent.change(screen.getByRole("combobox", { name: "Perfil: Test User" }), { target: { value: "editor" } });
    expect(confirmation).toHaveBeenCalledWith("Alterar o perfil de Test User para Editor?");
    expect(auth.authenticatedFetch).not.toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/memberships/${member.id}`,
      expect.objectContaining({ method: "PATCH" })
    );
    confirmation.mockRestore();
  });

  it("shows loading, empty, error, and retry states", async () => {
    auth.authenticatedFetch.mockResolvedValueOnce(new Response("", { status: 503 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ memberships: [] }), { status: 200 }));
    window.history.replaceState(null, "", "/administracao");
    render(<App />);
    expect(await screen.findByText("Não foi possível carregar os usuários. Tente novamente.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
    expect(await screen.findByText("Nenhum usuário encontrado.")).toBeInTheDocument();
  });

  it("shows last-admin protection and does not expose server details", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Configurações" }));
    await screen.findByText("Test User");
    auth.authenticatedFetch.mockResolvedValueOnce(new Response(JSON.stringify({ error: "private detail" }), { status: 409 }));
    fireEvent.click(screen.getByRole("button", { name: "Desativar" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("É necessário manter um administrador ativo.");
    expect(screen.getByRole("alert")).not.toHaveTextContent("private detail");
    vi.restoreAllMocks();
  });
});

describe("products UI", () => {
  const workspace = { id: "e97c159e-3f7b-4e27-8b1e-38036bf47a3f", name: "JLProject", role: "editor" };
  const product = { id: "e3aa998a-a2c3-4376-9105-90af0d1dbfe3", workspaceId: workspace.id,
    name: "Synthetic product", description: null, active: true, version: 1 };

  beforeEach(() => {
    auth.getSession.mockResolvedValue({ data: { session: { token: "valid-token" } }, error: null });
    auth.checkWorkspaceAccess.mockResolvedValue("authorized");
    auth.listMyWorkspaces.mockResolvedValue([workspace]);
    auth.authenticatedFetch.mockResolvedValue(new Response(JSON.stringify({ products: [product] }), { status: 200 }));
  });

  it("loads products and creates one through the same-origin API", async () => {
    render(<App />);
    expect(await screen.findByRole("link", { name: /Synthetic product/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Voltar" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Cadastrar produto" }));
    fireEvent.change(screen.getByLabelText("Nome"), { target: { value: "Novo teste" } });
    auth.authenticatedFetch.mockResolvedValueOnce(new Response(JSON.stringify({ product: { ...product, name: "Novo teste" } }), { status: 201 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ products: [{ ...product, name: "Novo teste" }] }), { status: 200 }));
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(auth.authenticatedFetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/products`, expect.objectContaining({ method: "POST" })
    ));
    expect(await screen.findByText("Produto criado.")).toBeInTheDocument();
  });

  it("opens a product schedule and restores the route after remount", async () => {
    auth.authenticatedFetch.mockImplementation((path: string) => Promise.resolve(new Response(JSON.stringify(
      path.endsWith("/hierarchy") ? { hierarchy: { productId: product.id, disciplines: [] } }
        : path.endsWith("/stage-definitions") ? { stageDefinitions: [] }
          : path.endsWith("/targets") ? { targets: [] } : { products: [product] }
    ), { status: 200 })));
    const first = render(<App />);
    fireEvent.click(await screen.findByRole("link", { name: /Synthetic product/ }));
    expect(await screen.findByText("Nenhuma disciplina cadastrada.")).toBeInTheDocument();
    expect(window.location.pathname).toBe(`/produtos/${product.id}/cronograma`);
    first.unmount();
    render(<App />);
    expect(await screen.findByText("Nenhuma disciplina cadastrada.")).toBeInTheDocument();
  });

  it("lets viewers read details without edit controls", async () => {
    auth.listMyWorkspaces.mockResolvedValue([{ ...workspace, role: "viewer" }]);
    render(<App />);
    expect(await screen.findByRole("link", { name: /Synthetic product/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Cadastrar produto" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Salvar" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Arquivar produto" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Importar planilha" })).not.toBeInTheDocument();
  });

  it("opens the preview-only import entry for editors", async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Importar planilha" }));
    expect(await screen.findByRole("heading", { name: "Importar planilha" })).toBeInTheDocument();
    expect(screen.getByText("As predecessoras da planilha serão ignoradas.")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Confirmar importação" })).not.toBeInTheDocument();
  });

  it("keeps the import picker mounted when the window regains focus and restores its route", async () => {
    const first = render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Importar planilha" }));
    const input = await screen.findByLabelText("Selecionar arquivo XLSX");
    fireEvent.focus(window);
    await waitFor(() => expect(auth.getSession).toHaveBeenCalledTimes(2));
    expect(screen.getByLabelText("Selecionar arquivo XLSX")).toBe(input);
    expect(window.location.pathname).toBe("/produtos/importar");
    first.unmount();
    render(<App />);
    expect(await screen.findByLabelText("Selecionar arquivo XLSX")).toBeInTheDocument();
  });

  it("shows loading, error, retry, and empty states", async () => {
    auth.authenticatedFetch.mockResolvedValueOnce(new Response("", { status: 503 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ products: [] }), { status: 200 }));
    window.history.replaceState(null, "", "/produtos");
    render(<App />);
    expect(await screen.findByText("Não foi possível carregar os produtos. Tente novamente.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
    expect(await screen.findByText("Nenhum produto encontrado.")).toBeInTheDocument();
  });

  it("keeps loading visible until products arrive and saves an edit", async () => {
    let resolveList!: (value: Response) => void;
    auth.authenticatedFetch.mockReturnValueOnce(new Promise((resolve) => { resolveList = resolve; }));
    window.history.replaceState(null, "", "/produtos");
    render(<App />);
    expect(await screen.findByText("Carregando produtos…")).toBeInTheDocument();
    resolveList(new Response(JSON.stringify({ products: [product] }), { status: 200 }));
    fireEvent.click(await screen.findByLabelText(`Configurações do produto: ${product.name}`));
    fireEvent.click(screen.getByRole("button", { name: "Editar produto" }));
    fireEvent.change(screen.getByLabelText("Nome"), { target: { value: "Produto atualizado" } });
    auth.authenticatedFetch.mockResolvedValueOnce(new Response(JSON.stringify({ product: { ...product, name: "Produto atualizado", version: 2 } }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ products: [{ ...product, name: "Produto atualizado", version: 2 }] }), { status: 200 }));
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(auth.authenticatedFetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/products/${product.id}`,
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"version":1') })
    ));
    expect(await screen.findByText("Produto atualizado.")).toBeInTheDocument();
  });

  it("confirms archive and reports a duplicate without leaking response details", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<App />);
    fireEvent.click(await screen.findByLabelText(`Configurações do produto: ${product.name}`));
    fireEvent.click(screen.getByRole("button", { name: "Editar produto" }));
    auth.authenticatedFetch.mockResolvedValueOnce(new Response(JSON.stringify({ code: "duplicate", error: "private detail" }), { status: 409 }));
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Já existe um produto com esse nome");
    expect(screen.getByRole("alert")).not.toHaveTextContent("private detail");
    auth.authenticatedFetch.mockResolvedValueOnce(new Response(JSON.stringify({ product: { ...product, active: false } }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ products: [{ ...product, active: false }] }), { status: 200 }));
    fireEvent.click(screen.getByRole("button", { name: "Arquivar produto" }));
    await waitFor(() => expect(confirmation).toHaveBeenCalledWith("Arquivar o produto Synthetic product?"));
    expect(await screen.findByText("Produto arquivado.")).toBeInTheDocument();
    confirmation.mockRestore();
  });

  it("shows real hierarchy counts on cards and marks product history unavailable", async () => {
    auth.authenticatedFetch.mockImplementation((path: string) => Promise.resolve(new Response(JSON.stringify(
      path.endsWith("/hierarchy") ? { hierarchy: { disciplines: [
        { stages: [{ activities: [{}, {}] }, { activities: [] }] }, { stages: [{ activities: [{}] }] }
      ] } } : { products: [product] }
    ), { status: 200 })));
    render(<App />);
    await waitFor(() => expect(screen.getAllByText(/^[0-9]+$/, { selector: ".product-card__counts dd" })
      .map((element) => element.textContent)).toEqual(["3", "2", "3"]));
    expect(screen.getByRole("button", { name: `Histórico do produto: ${product.name}` })).toHaveAttribute("aria-disabled", "true");
    expect(screen.getByRole("button", { name: `Histórico do produto: ${product.name}` })).toHaveAttribute(
      "title", "Histórico de alterações do produto ainda não disponível."
    );
  });

  it("opens the existing edit form from the contextual product menu", async () => {
    render(<App />);
    fireEvent.click(await screen.findByLabelText(`Configurações do produto: ${product.name}`));
    fireEvent.click(screen.getByRole("button", { name: "Editar produto" }));
    expect(await screen.findByLabelText("Nome")).toHaveValue("Synthetic product");
    expect(screen.getByRole("button", { name: "Arquivar produto" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Abrir cronograma" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Arquivar produto" }).closest("form")).toBeNull();
    expect(screen.getByRole("button", { name: "Salvar" }).closest(".product-form__actions")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Cancelar" }).closest(".product-form__actions")).toBeInTheDocument();
  });

  it("discards unsaved product edits and returns to cards without an API write", async () => {
    render(<App />);
    fireEvent.click(await screen.findByLabelText(`Configurações do produto: ${product.name}`));
    fireEvent.click(screen.getByRole("button", { name: "Editar produto" }));
    fireEvent.change(await screen.findByLabelText("Nome"), { target: { value: "Unsaved product name" } });
    fireEvent.change(screen.getByLabelText("Descrição"), { target: { value: "Unsaved description" } });
    const callCountBeforeCancel = auth.authenticatedFetch.mock.calls.length;

    fireEvent.click(screen.getByRole("button", { name: "Cancelar" }));

    expect(await screen.findByRole("link", { name: /Synthetic product/ })).toBeInTheDocument();
    expect(screen.queryByLabelText("Nome")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Abrir cronograma" })).not.toBeInTheDocument();
    expect(auth.authenticatedFetch).toHaveBeenCalledTimes(callCountBeforeCancel);
  });
});

afterEach(() => {
  vi.unstubAllEnvs();
  window.history.replaceState(null, "", "/");
});

describe("authentication UI", () => {
  it("renders the fixed global header with inactive future actions and working logout", async () => {
    auth.getSession.mockResolvedValue({
      data: { session: { token: "valid-token" }, user: { name: "Paulo Eduardo", email: "paulo@example.com" } },
      error: null
    });
    auth.checkWorkspaceAccess.mockResolvedValue("authorized");
    auth.listMyWorkspaces.mockResolvedValue([]);

    render(<App />);

    expect(await screen.findByRole("img", { name: "JLProject" })).toBeInTheDocument();
    expect(screen.getByText("Sistema de Cronogramas de Produto")).toBeInTheDocument();
    expect(screen.getByText(/Paulo! Que seu dia seja lindo ❤️/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Configurações" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Devloop" })).toBeDisabled();

    fireEvent.click(screen.getByRole("button", { name: "Sair" }));
    await waitFor(() => expect(auth.signOut).toHaveBeenCalledOnce());
    expect(await screen.findByRole("heading", { name: "Entrar" })).toBeInTheDocument();
  });

  it("shows Portuguese loading and login states", async () => {
    render(<App />);
    expect(screen.getByRole("status")).toHaveTextContent("Verificando sessão");
    expect(screen.getByRole("heading", { name: "Gerenciamento de Projetos" })).toBeInTheDocument();
    expect(await screen.findByRole("heading", { name: "Entrar" })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: "JLProject" })).toHaveAttribute("src", "/brand/jlproject-logo.svg");
    expect(screen.getByText("Sistema de Cronogramas de Produto")).toBeInTheDocument();
    expect(screen.queryByRole("navigation")).not.toBeInTheDocument();
  });

  it("shows a generic error for failed credentials", async () => {
    auth.signIn.mockResolvedValue({ data: null, error: { code: "INVALID_PASSWORD" } });
    render(<App />);
    await screen.findByRole("heading", { name: "Entrar" });
    fireEvent.change(screen.getByLabelText("E-mail"), { target: { value: "test@example.com" } });
    fireEvent.change(screen.getByLabelText("Senha"), { target: { value: "wrongpassword" } });
    fireEvent.click(screen.getByRole("button", { name: "Entrar" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível entrar");
    expect(screen.getByRole("alert")).not.toHaveTextContent("INVALID_PASSWORD");
  });

  it("completes sign-in and waits for Worker authorization", async () => {
    auth.getSession
      .mockResolvedValueOnce({ data: null, error: null })
      .mockResolvedValueOnce({ data: { session: { token: "signed-token" } }, error: null });
    render(<App />);
    await screen.findByRole("heading", { name: "Entrar" });
    fireEvent.change(screen.getByLabelText("E-mail"), { target: { value: "test@example.com" } });
    fireEvent.change(screen.getByLabelText("Senha"), { target: { value: "test-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Entrar" }));

    expect(await screen.findByRole("heading", { name: "Acesso pendente" })).toBeInTheDocument();
    expect(auth.signIn).toHaveBeenCalledWith({ email: "test@example.com", password: "test-password" });
    expect(auth.checkWorkspaceAccess).toHaveBeenCalledWith("signed-token");
  });

  it("restores the provider session after an application remount", async () => {
    auth.getSession.mockResolvedValue({ data: { session: { token: "valid-token" } }, error: null });
    const first = render(<App />);
    expect(await screen.findByRole("heading", { name: "Acesso pendente" })).toBeInTheDocument();
    first.unmount();

    render(<App />);
    expect(screen.getByRole("status")).toHaveTextContent("Verificando sessão");
    expect(await screen.findByRole("heading", { name: "Acesso pendente" })).toBeInTheDocument();
    expect(auth.getSession).toHaveBeenCalledTimes(2);
  });

  it("keeps loading visible until asynchronous restoration finishes", async () => {
    let resolveSession!: (value: unknown) => void;
    auth.getSession.mockReturnValue(new Promise((resolve) => { resolveSession = resolve; }));
    render(<App />);
    expect(screen.getByRole("status")).toHaveTextContent("Verificando sessão");
    expect(screen.queryByRole("heading", { name: "Entrar" })).not.toBeInTheDocument();

    resolveSession({ data: null, error: null });
    expect(await screen.findByRole("heading", { name: "Entrar" })).toBeInTheDocument();
  });

  it("shows a retry state when restoration temporarily fails", async () => {
    auth.getSession
      .mockRejectedValueOnce(new Error("temporary network failure"))
      .mockResolvedValueOnce({ data: { session: { token: "valid-token" } }, error: null });
    render(<App />);
    expect(await screen.findByRole("heading", { name: "Verificação de sessão" })).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("Não foi possível verificar sua sessão");
    expect(screen.queryByRole("heading", { name: "Entrar" })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
    expect(await screen.findByRole("heading", { name: "Acesso pendente" })).toBeInTheDocument();
  });

  it("restores a session, denies workspace access, and signs out", async () => {
    auth.getSession.mockResolvedValue({ data: { session: { token: "signed-token" } }, error: null });
    render(<App />);
    expect(await screen.findByRole("heading", { name: "Acesso pendente" })).toBeInTheDocument();
    expect(auth.checkWorkspaceAccess).toHaveBeenCalledWith("signed-token");
    fireEvent.click(screen.getByRole("button", { name: "Sair" }));
    await waitFor(() => expect(auth.signOut).toHaveBeenCalledOnce());
    expect(await screen.findByRole("heading", { name: "Entrar" })).toBeInTheDocument();
  });

  it("does not mistake a rejected Worker token for a provider logout", async () => {
    auth.getSession.mockResolvedValue({ data: { session: { token: "expired-token" } }, error: null });
    auth.checkWorkspaceAccess.mockResolvedValue("expired");
    render(<App />);
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível validar sua sessão");
    expect(screen.getByRole("heading", { name: "Verificação de sessão" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Entrar" })).not.toBeInTheDocument();
  });

  it("shows login after logout and an application remount", async () => {
    auth.getSession
      .mockResolvedValueOnce({ data: { session: { token: "valid-token" } }, error: null })
      .mockResolvedValueOnce({ data: null, error: null });
    const first = render(<App />);
    expect(await screen.findByRole("heading", { name: "Acesso pendente" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Sair" }));
    expect(await screen.findByRole("heading", { name: "Entrar" })).toBeInTheDocument();
    first.unmount();

    render(<App />);
    expect(await screen.findByRole("heading", { name: "Entrar" })).toBeInTheDocument();
    expect(auth.signOut).toHaveBeenCalledOnce();
  });

  it("requests recovery without revealing whether the account exists", async () => {
    render(<App />);
    await screen.findByRole("heading", { name: "Entrar" });
    fireEvent.click(screen.getByRole("button", { name: "Esqueci minha senha" }));
    fireEvent.change(screen.getByLabelText("E-mail"), { target: { value: "test@example.com" } });
    fireEvent.click(screen.getByRole("button", { name: "Enviar link de recuperação" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Se o endereço estiver cadastrado");
    expect(auth.requestPasswordReset).toHaveBeenCalledWith({
      email: "test@example.com", redirectTo: `${window.location.origin}/reset-password`
    });
  });

  it("uses a reset token and removes it from browser history", async () => {
    window.history.replaceState(null, "", "/reset-password?token=temporary-token");
    render(<App />);
    expect(screen.getByRole("heading", { name: "Definir nova senha" })).toBeInTheDocument();
    expect(window.location.search).toBe("");
    fireEvent.change(screen.getByLabelText("Nova senha"), { target: { value: "new-password-123" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar nova senha" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Senha alterada");
    expect(auth.resetPassword).toHaveBeenCalledWith({ newPassword: "new-password-123", token: "temporary-token" });
  });

  it("sends and confirms an email verification code", async () => {
    render(<App />);
    await screen.findByRole("heading", { name: "Entrar" });
    fireEvent.click(screen.getByRole("button", { name: "Verificar e-mail" }));
    fireEvent.change(screen.getByLabelText("E-mail"), { target: { value: "test@example.com" } });
    fireEvent.click(screen.getByRole("button", { name: "Enviar código" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("você receberá um código");
    fireEvent.change(screen.getByLabelText("Código de verificação"), { target: { value: "123456" } });
    fireEvent.click(screen.getByRole("button", { name: "Confirmar código" }));
    expect(await screen.findByRole("heading", { name: "Entrar" })).toBeInTheDocument();
    expect(auth.verifyEmailCode).toHaveBeenCalledWith("test@example.com", "123456");
  });
});
