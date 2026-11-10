import { lazy, Suspense, type FormEvent, useCallback, useEffect, useState } from "react";
import { authenticatedFetch, type WorkspaceSummary } from "./auth";
import { messages } from "./locales/pt-BR";
import { ScheduleEditor } from "./ScheduleEditor";

const ImportPreview = lazy(() => import("./ImportPreview").then((module) => ({ default: module.ImportPreview })));

interface Product {
  id: string;
  workspaceId: string;
  name: string;
  description: string | null;
  active: boolean;
  version: number;
}

interface ProductCounts {
  activities: number;
  disciplines: number;
  stages: number;
}

interface ProductHierarchy {
  disciplines: { stages: { activities: unknown[] }[] }[];
}

export function Products({ workspace, onAccessLost }: {
  workspace: WorkspaceSummary;
  onAccessLost: () => void;
}) {
  const [products, setProducts] = useState<Product[]>([]);
  const [productCounts, setProductCounts] = useState<Record<string, ProductCounts | null>>({});
  const [countsLoading, setCountsLoading] = useState(false);
  const [state, setState] = useState<"loading" | "ready" | "error">("loading");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");
  const [cloneSource, setCloneSource] = useState<Product | null>(null);
  const [cloneName, setCloneName] = useState("");
  const [cloneError, setCloneError] = useState("");
  const [openMenuProductId, setOpenMenuProductId] = useState<string | null>(null);
  const [scheduleProductId, setScheduleProductId] = useState<string | null>(() =>
    window.location.pathname.match(/^\/produtos\/([0-9a-f-]{36})\/cronograma$/i)?.[1] ?? null
  );
  const [showImport, setShowImport] = useState(() => window.location.pathname === "/produtos/importar");
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
      if (!Array.isArray(data.products)) throw new Error("Product response is invalid.");
      setProducts(data.products);
      setProductCounts({});
      setState("ready");
      setCountsLoading(data.products.length > 0);
      const countResults = await Promise.all(data.products.map(async (product) => {
        try {
          const hierarchyResponse = await authenticatedFetch(`${endpoint}/${product.id}/hierarchy`);
          if (hierarchyResponse.status === 401 || hierarchyResponse.status === 403) {
            onAccessLost();
            return [product.id, null] as const;
          }
          if (!hierarchyResponse.ok) return [product.id, null] as const;
          const payload = await hierarchyResponse.json() as { hierarchy: ProductHierarchy };
          const disciplines = payload.hierarchy.disciplines;
          return [product.id, {
            disciplines: disciplines.length,
            stages: disciplines.reduce((total, discipline) => total + discipline.stages.length, 0),
            activities: disciplines.reduce((total, discipline) => total + discipline.stages.reduce(
              (stageTotal, stage) => stageTotal + stage.activities.length, 0
            ), 0)
          }] as const;
        } catch { return [product.id, null] as const; }
      }));
      setProductCounts(Object.fromEntries(countResults));
      setCountsLoading(false);
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

  function openSchedule(product: Product) {
    window.history.pushState(null, "", `/produtos/${product.id}/cronograma`);
    setScheduleProductId(product.id);
    setSelectedId(null);
    setOpenMenuProductId(null);
  }

  function newProduct() {
    setSelectedId(null);
    setCreating(true);
    setName("");
    setDescription("");
    setFeedback("");
  }

  function cancelEdit() {
    setSelectedId(null);
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

  async function archive(product: Product | null = selected) {
    if (!canEdit || !product?.active || busy || !window.confirm(messages.confirmProductArchive(product.name))) return;
    setBusy(true);
    setFeedback("");
    try {
      const response = await authenticatedFetch(`${endpoint}/${product.id}/archive`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ version: product.version })
      });
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) {
        const data = await response.json() as { code?: string };
        setFeedback(data.code === "stale" ? messages.productStale : messages.productArchiveError);
        return;
      }
      await load();
      if (selectedId === product.id) setSelectedId(null);
      setOpenMenuProductId(null);
      setFeedback(messages.productArchived);
    } catch { setFeedback(messages.productArchiveError); }
    finally { setBusy(false); }
  }

  function startClone(product: Product) {
    const suffix = " (cópia)";
    setCloneSource(product);
    setCloneName(`${product.name.slice(0, 200 - suffix.length)}${suffix}`);
    setCloneError("");
    setFeedback("");
    setOpenMenuProductId(null);
  }

  async function cloneProduct(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canEdit || !cloneSource || busy) return;
    const requestedName = cloneName.trim();
    if (!requestedName || requestedName.length > 200) {
      setCloneError(messages.cloneProductInvalidName);
      return;
    }
    setBusy(true);
    setCloneError("");
    try {
      const response = await authenticatedFetch(`${endpoint}/${cloneSource.id}/clone`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: requestedName })
      });
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) {
        const data = await response.json() as { code?: string };
        setCloneError(data.code === "duplicate" ? messages.productDuplicate
          : response.status === 404 ? messages.cloneProductSourceMissing : messages.cloneProductError);
        return;
      }
      setCloneSource(null);
      await load();
      setFeedback(messages.cloneProductSuccess);
    } catch { setCloneError(messages.cloneProductError); }
    finally { setBusy(false); }
  }

  if (showImport && canEdit) return <Suspense fallback={<p role="status">{messages.importLoading}</p>}>
    <ImportPreview workspaceId={workspace.id} onAccessLost={onAccessLost}
      onImported={(productId) => {
        window.history.pushState(null, "", `/produtos/${productId}/cronograma`);
        setScheduleProductId(productId);
        setShowImport(false);
        void load();
      }}
      onBack={() => { window.history.pushState(null, "", "/produtos"); setShowImport(false); }} />
  </Suspense>;

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
      <div className="products-heading">
        <h2 id="products-title">{messages.products}</h2>
        {canEdit && <div className="products-primary-actions">
          <button type="button" disabled={busy} onClick={newProduct}>{messages.registerProduct}</button>
          <button type="button" disabled={busy} onClick={() => {
            window.history.pushState(null, "", "/produtos/importar");
            setShowImport(true);
          }}>{messages.importTitle}</button>
        </div>}
      </div>
      {state === "loading" && <p role="status">{messages.productsLoading}</p>}
      {state === "error" && <div role="alert"><p>{messages.productsError}</p><button type="button" onClick={() => void load()}>{messages.retry}</button></div>}
      {state === "ready" && products.length === 0 && <p>{messages.productsEmpty}</p>}
      {state === "ready" && products.length > 0 && (
        <ul className="product-list">
          {products.map((product) => (
            <li className="product-card" key={product.id}>
              <a className="product-card__body" href={`/produtos/${product.id}/cronograma`}
                onClick={(event) => { event.preventDefault(); openSchedule(product); }}>
                <div className="product-card__topline">
                  <span className="product-card__open">
                  {product.name}
                  </span>
                  <span className={`product-card__status${product.active ? "" : " product-card__status--archived"}`}>
                    {product.active ? messages.active : messages.archived}
                  </span>
                </div>
                <dl className="product-card__counts" aria-label={messages.scheduleCounts}>
                  {countsLoading && productCounts[product.id] === undefined ? <div className="product-card__count-message">{messages.scheduleCountsLoading}</div>
                    : productCounts[product.id] ? <>
                      <div><dt>{messages.activities}</dt><dd>{productCounts[product.id]!.activities.toLocaleString("pt-BR")}</dd></div>
                      <div><dt>{messages.disciplines}</dt><dd>{productCounts[product.id]!.disciplines.toLocaleString("pt-BR")}</dd></div>
                      <div><dt>{messages.stages}</dt><dd>{productCounts[product.id]!.stages.toLocaleString("pt-BR")}</dd></div>
                    </> : <div className="product-card__count-message">{messages.scheduleCountsUnavailable}</div>}
                </dl>
              </a>
              <div className="product-card__actions">
                <button type="button" className="product-card__icon" aria-disabled="true"
                  aria-describedby={`product-history-help-${product.id}`} title={messages.productHistoryUnavailable}
                  aria-label={`${messages.productHistory}: ${product.name}`}>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5.5h16M4 10h16M4 14.5h10M4 19h10" /></svg>
                </button>
                <span className="visually-hidden" id={`product-history-help-${product.id}`}>{messages.productHistoryUnavailable}</span>
                {canEdit && product.active && <div className="product-card__menu">
                  <button type="button" className="product-card__menu-trigger"
                    aria-label={`${messages.productActions}: ${product.name}`} title={messages.productActions}
                    aria-controls={`product-menu-${product.id}`} aria-expanded={openMenuProductId === product.id}
                    onClick={() => setOpenMenuProductId(openMenuProductId === product.id ? null : product.id)}>
                    <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="5" cy="12" r="1" /><circle cx="12" cy="12" r="1" /><circle cx="19" cy="12" r="1" /></svg>
                  </button>
                  {openMenuProductId === product.id && <div className="product-card__menu-items" id={`product-menu-${product.id}`}>
                    <button type="button" onClick={() => {
                      selectProduct(product);
                      setOpenMenuProductId(null);
                    }}>{messages.editProduct}</button>
                    <button type="button" onClick={() => startClone(product)}>{messages.cloneProduct}</button>
                    <button type="button" onClick={() => void archive(product)}>{messages.archiveProduct}</button>
                  </div>}
                </div>}
              </div>
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
              <div className="product-form__actions">
                <button type="submit" disabled={busy}>{messages.save}</button>
                <button type="button" className="back-button" disabled={busy} onClick={cancelEdit}>{messages.cancel}</button>
              </div>
            </form>
          ) : (
            <dl><dt>{messages.productName}</dt><dd>{selected.name}</dd><dt>{messages.productDescription}</dt><dd>{selected.description || messages.noDescription}</dd></dl>
          )}
          {canEdit && selected.active && <div className="product-detail-actions">
            <button type="button" disabled={busy} onClick={() => void archive(selected)}>{messages.archiveProduct}</button>
          </div>}
        </section>
      )}
      {cloneSource && canEdit && <div className="schedule-drawer-backdrop" onMouseDown={(event) => {
        if (event.target === event.currentTarget && !busy) setCloneSource(null);
      }}><form className="milestone-dialog" role="dialog" aria-modal="true"
        aria-labelledby="clone-product-title" onSubmit={(event) => void cloneProduct(event)}>
        <h3 id="clone-product-title">{messages.cloneProductTitle}</h3>
        <label htmlFor="clone-product-name">{messages.cloneProductName}</label>
        <input id="clone-product-name" autoFocus required maxLength={200} value={cloneName}
          onChange={(event) => setCloneName(event.target.value)} aria-invalid={!!cloneError}
          aria-describedby={cloneError ? "clone-product-error" : undefined} />
        {cloneError && <p id="clone-product-error" role="alert">{cloneError}</p>}
        <div className="product-form__actions">
          <button type="submit" disabled={busy || !cloneName.trim()}>
            {busy ? messages.cloningProduct : messages.cloneProductSubmit}
          </button>
          <button type="button" className="back-button" disabled={busy}
            onClick={() => setCloneSource(null)}>{messages.cancel}</button>
        </div>
      </form></div>}
      {feedback && <p role="alert" className="feedback">{feedback}</p>}
    </section>
  );
}
