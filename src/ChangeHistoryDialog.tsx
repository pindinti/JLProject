import { type KeyboardEvent, type ReactNode, useEffect, useRef } from "react";

export function ChangeHistoryDialog({ title, closeLabel, onClose, children, footer, className = "" }: {
  title: string; closeLabel: string; onClose: () => void; children: ReactNode; footer: ReactNode;
  className?: string;
}) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const previousFocus = useRef<HTMLElement | null>(null);
  useEffect(() => {
    previousFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    dialogRef.current?.querySelector<HTMLElement>("button, input, select, textarea, [tabindex='0']")?.focus();
    return () => queueMicrotask(() => previousFocus.current?.focus());
  }, []);
  function handleKeys(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape") { event.preventDefault(); onClose(); return; }
    if (event.key !== "Tab" || !dialogRef.current) return;
    const items = [...dialogRef.current.querySelectorAll<HTMLElement>(
      "button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), summary, [tabindex='0']"
    )].filter((item) => item.getAttribute("aria-hidden") !== "true");
    if (!items.length) return;
    const first = items[0]; const last = items[items.length - 1];
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  }
  return <div className="change-history-backdrop" onMouseDown={(event) => {
    if (event.target === event.currentTarget) onClose();
  }}>
    <section ref={dialogRef} className={`change-history-dialog ${className}`.trim()} role="dialog" aria-modal="true"
      aria-labelledby="change-history-title" onKeyDown={handleKeys}>
      <header className="change-history-dialog__header">
        <h2 id="change-history-title">{title}</h2>
        <button type="button" className="change-history-dialog__close" aria-label={closeLabel}
          title={closeLabel} onClick={onClose}>×</button>
      </header>
      <div className="change-history-dialog__body">{children}</div>
      <footer className="change-history-dialog__footer">{footer}</footer>
    </section>
  </div>;
}
