import { type FormEvent, useCallback, useEffect, useState } from "react";
import { authenticatedFetch, type WorkspaceSummary } from "./auth";
import { messages } from "./locales/pt-BR";
import { ScheduleEditor } from "./ScheduleEditor";

interface Product {
  id: string;
  workspaceId: string;
  name: string;
  description: string | null;
  active: boolean;
  version: number;
}

export function Products({ workspace, onBack, onAccessLost }: {
  workspace: WorkspaceSummary;
  onBack: () => void;
  onAccessLost: () => void;
}) {
  const [products, setProducts] = useState<Product[]>([]);
  const [state, setState] = useState<"loading" | "ready" | "error">("loading");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");
  const [scheduleProductId, setScheduleProductId] = useState<string | null>(() =>
    window.location.pathname.match(/^\/produtos\/([0-9a-f-]{36})\/cronograma$/i)?.[1] ?? null
  );
  const canEdit = workspace.role === "admin" || workspace.role === "editor";
  const endpoint = `/api/workspaces/${workspace.id}/products`;
  const selected = products.find((product) => product.id === selectedId) ?? null;

  const load = useCallback(async () => {
    setState("loading");
    try {
      const response = await authenticatedFetch(endpoint);
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) throw new Error("Product lookup failed.");
      const data = await response.json() as { products: Product[] };
      setProducts(data.products);
      setState("ready");
    } catch { setState("error"); }
  }, [endpoint, onAccessLost]);

  useEffect(() => { queueMicrotask(() => void load()); }, [load]);

  function selectProduct(product: Product) {
    setCreating(false);
    setSelectedId(product.id);
    setName(product.name);
    setDescription(product.description ?? "");
    setFeedback("");
  }

  function newProduct() {
    setSelectedId(null);
    setCreating(true);
    setName("");
    setDescription("");
    setFeedback("");
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canEdit || busy) return;
    setBusy(true);
    setFeedback("");
    try {
      const response = await authenticatedFetch(creating ? endpoint : `${endpoint}/${selectedId}`, {
        method: creating ? "POST" : "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, description, ...(!creating && selected ? { version: selected.version } : {}) })
      });
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) {
        const data = await response.json() as { code?: string };
        setFeedback(data.code === "duplicate" ? messages.productDuplicate
          : data.code === "stale" ? messages.productStale : messages.productSaveError);
        return;
      }
      const data = await response.json() as { product: Product };
      await load();
      setCreating(false);
      setSelectedId(data.product.id);
      setName(data.product.name);
      setDescription(data.product.description ?? "");
      setFeedback(creating ? messages.productCreated : messages.productSaved);
    } catch { setFeedback(messages.productSaveError); }
    finally { setBusy(false); }
  }

  async function archive() {
    if (!canEdit || !selected?.active || busy || !window.confirm(messages.confirmProductArchive(selected.name))) return;
    setBusy(true);
    setFeedback("");
    try {
      const response = await authenticatedFetch(`${endpoint}/${selected.id}/archive`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ version: selected.version })
      });
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) {
        const data = await response.json() as { code?: string };
        setFeedback(data.code === "stale" ? messages.productStale : messages.productArchiveError);
        return;
      }
      await load();
      setSelectedId(null);
      setFeedback(messages.productArchived);
    } catch { setFeedback(messages.productArchiveError); }
    finally { setBusy(false); }
  }

  if (scheduleProductId) {
    const scheduleProduct = products.find((item) => item.id === scheduleProductId);
    const backToProducts = () => {
      window.history.pushState(null, "", "/produtos");
      setScheduleProductId(null);
    };
    if (state === "loading") return <p role="status">{messages.productsLoading}</p>;
    if (state === "error") return <div role="alert"><p>{messages.productsError}</p>
      <button type="button" onClick={() => void load()}>{messages.retry}</button></div>;
    return scheduleProduct
      ? <ScheduleEditor workspace={workspace} product={scheduleProduct}
          onBack={backToProducts} onAccessLost={onAccessLost} />
      : <div role="alert"><p>{messages.scheduleNotFound}</p>
          <button type="button" onClick={backToProducts}>{messages.backToProducts}</button></div>;
  }

  return (
    <section className="products" aria-labelledby="products-title">
      <h2 id="products-title">{messages.products}</h2>
      <p>{workspace.name}</p>
      {canEdit && <button type="button" disabled={busy} onClick={newProduct}>{messages.newProduct}</button>}
      {state === "loading" && <p role="status">{messages.productsLoading}</p>}
      {state === "error" && <div role="alert"><p>{messages.productsError}</p><button type="button" onClick={() => void load()}>{messages.retry}</button></div>}
      {state === "ready" && products.length === 0 && <p>{messages.productsEmpty}</p>}
      {state === "ready" && products.length > 0 && (
        <ul className="product-list">
          {products.map((product) => (
            <li key={product.id}>
              <button type="button" className="product-link" onClick={() => selectProduct(product)}>
                <span>{product.name}</span>
                <span>{product.active ? messages.active : messages.archived}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {creating && canEdit && (
        <form className="product-form" onSubmit={(event) => void save(event)}>
          <h3>{messages.newProduct}</h3>
          <label htmlFor="product-name">{messages.productName}</label>
          <input id="product-name" required maxLength={200} value={name} onChange={(event) => setName(event.target.value)} />
          <label htmlFor="product-description">{messages.productDescription}</label>
          <textarea id="product-description" maxLength={2000} value={description} onChange={(event) => setDescription(event.target.value)} />
          <button type="submit" disabled={busy}>{messages.save}</button>
          <button type="button" className="back-button" onClick={() => setCreating(false)}>{messages.cancel}</button>
        </form>
      )}
      {selected && !creating && (
        <section className="product-details" aria-labelledby="product-details-title">
          <h3 id="product-details-title">{messages.productDetails}</h3>
          {canEdit && selected.active ? (
            <form className="product-form" onSubmit={(event) => void save(event)}>
              <label htmlFor="product-name">{messages.productName}</label>
              <input id="product-name" required maxLength={200} value={name} onChange={(event) => setName(event.target.value)} />
              <label htmlFor="product-description">{messages.productDescription}</label>
              <textarea id="product-description" maxLength={2000} value={description} onChange={(event) => setDescription(event.target.value)} />
              <button type="submit" disabled={busy}>{messages.save}</button>
            </form>
          ) : (
            <dl><dt>{messages.productName}</dt><dd>{selected.name}</dd><dt>{messages.productDescription}</dt><dd>{selected.description || messages.noDescription}</dd></dl>
          )}
          {canEdit && selected.active && <button type="button" disabled={busy} onClick={() => void archive()}>{messages.archiveProduct}</button>}
          <button type="button" onClick={() => {
            window.history.pushState(null, "", `/produtos/${selected.id}/cronograma`);
            setScheduleProductId(selected.id);
          }}>{messages.openSchedule}</button>
        </section>
      )}
      {feedback && <p role="alert" className="feedback">{feedback}</p>}
      <button type="button" className="back-button" onClick={onBack}>{messages.back}</button>
    </section>
  );
}
