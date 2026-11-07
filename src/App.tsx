import { messages } from "./locales/pt-BR";

export function App() {
  return (
    <main className="application-shell" aria-labelledby="application-title">
      <section className="application-card">
        <p className="application-brand">{messages.applicationName}</p>
        <h1 id="application-title">{messages.applicationSubtitle}</h1>
        <p className="application-status" role="status">
          {messages.applicationStatus}
        </p>
      </section>
    </main>
  );
}
