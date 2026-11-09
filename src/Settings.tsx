import { Administration } from "./Administration";
import type { WorkspaceSummary } from "./auth";
import { messages } from "./locales/pt-BR";

export function Settings({ adminWorkspace, onAccessLost, onBack }: {
  adminWorkspace: WorkspaceSummary | null;
  onAccessLost: () => void;
  onBack: () => void;
}) {
  return (
    <section className="settings-view" aria-labelledby="settings-title">
      <header className="settings-view__heading">
        <div>
          <h2 id="settings-title">{messages.settings}</h2>
          <p>{messages.settingsDescription}</p>
        </div>
        <button className="back-button" type="button" onClick={onBack}>{messages.backToProducts}</button>
      </header>
      <div className="settings-view__planned">
        <section aria-labelledby="profile-settings-title">
          <h3 id="profile-settings-title">{messages.profileSettings}</h3>
          <p>{messages.settingsPlanned}</p>
        </section>
        <section aria-labelledby="notification-settings-title">
          <h3 id="notification-settings-title">{messages.notificationSettings}</h3>
          <p>{messages.settingsPlanned}</p>
        </section>
      </div>
      {adminWorkspace && <Administration workspace={adminWorkspace} onAccessLost={onAccessLost} />}
    </section>
  );
}
