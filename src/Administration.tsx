import { useCallback, useEffect, useState } from "react";
import { authenticatedFetch, type WorkspaceSummary } from "./auth";
import { messages } from "./locales/pt-BR";

type Role = "admin" | "editor" | "viewer";
interface Member {
  id: string;
  name: string;
  email: string;
  role: Role;
  active: boolean;
}

const roleLabels: Record<Role, string> = {
  admin: messages.roleAdmin, editor: messages.roleEditor, viewer: messages.roleViewer
};

export function Administration({ workspace, onBack, onAccessLost }: {
  workspace: WorkspaceSummary;
  onBack: () => void;
  onAccessLost: () => void;
}) {
  const [members, setMembers] = useState<Member[]>([]);
  const [state, setState] = useState<"loading" | "ready" | "error">("loading");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [feedback, setFeedback] = useState("");
  const endpoint = `/api/workspaces/${workspace.id}/memberships`;

  const load = useCallback(async () => {
    setState("loading");
    try {
      const response = await authenticatedFetch(endpoint);
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) throw new Error("Membership lookup failed.");
      const data = await response.json() as { memberships: Member[] };
      setMembers(data.memberships);
      setState("ready");
    } catch {
      setState("error");
    }
  }, [endpoint, onAccessLost]);

  useEffect(() => { queueMicrotask(() => void load()); }, [load]);

  async function changeMember(member: Member, change: { role: Role } | { active: boolean }) {
    const confirmation = "role" in change
      ? messages.confirmRoleChange(member.name, roleLabels[change.role])
      : messages.confirmStatusChange(member.name, change.active);
    if (!window.confirm(confirmation)) return;
    setBusyId(member.id);
    setFeedback("");
    try {
      const response = await authenticatedFetch(`${endpoint}/${member.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(change)
      });
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (response.status === 409) {
        setFeedback(messages.lastAdminError);
        return;
      }
      if (!response.ok) throw new Error("Membership update failed.");
      setFeedback(messages.membershipSaved);
      await load();
    } catch {
      setFeedback(messages.membershipError);
    } finally {
      setBusyId(null);
    }
  }

  return (
    <section className="administration" aria-labelledby="administration-title">
      <h2 id="administration-title">{messages.administration}</h2>
      <p>{workspace.name}</p>
      <h3>{messages.users}</h3>
      {state === "loading" && <p role="status">{messages.membersLoading}</p>}
      {state === "error" && (
        <div role="alert">
          <p>{messages.membersError}</p>
          <button type="button" onClick={() => void load()}>{messages.retry}</button>
        </div>
      )}
      {state === "ready" && members.length === 0 && <p>{messages.membersEmpty}</p>}
      {state === "ready" && members.length > 0 && (
        <ul className="member-list">
          {members.map((member) => (
            <li key={member.id} className="member-row">
              <div className="member-identity"><strong>{member.name}</strong><span>{member.email}</span></div>
              <label>
                <span>{messages.role}</span>
                <select aria-label={`${messages.role}: ${member.name}`} value={member.role}
                  disabled={busyId !== null}
                  onChange={(event) => void changeMember(member, { role: event.target.value as Role })}>
                  <option value="admin">{messages.roleAdmin}</option>
                  <option value="editor">{messages.roleEditor}</option>
                  <option value="viewer">{messages.roleViewer}</option>
                </select>
              </label>
              <span className="member-status">{member.active ? messages.active : messages.inactive}</span>
              <button type="button" disabled={busyId !== null}
                onClick={() => void changeMember(member, { active: !member.active })}>
                {member.active ? messages.deactivate : messages.activate}
              </button>
            </li>
          ))}
        </ul>
      )}
      {feedback && <p role="alert" className="feedback">{feedback}</p>}
      <button className="back-button" type="button" onClick={onBack}>{messages.back}</button>
    </section>
  );
}
