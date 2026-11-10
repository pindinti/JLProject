import { type FormEvent, useCallback, useEffect, useRef, useState } from "react";
import {
  authClient,
  checkWorkspaceAccess,
  listMyWorkspaces,
  type WorkspaceSummary,
  sendEmailVerificationCode,
  verifyEmailCode
} from "./auth";
import { messages } from "./locales/pt-BR";
import { Products } from "./Products";
import { Settings } from "./Settings";
import { getFirstName, getGreeting } from "./design/header";

type View = "loading" | "login" | "recovery" | "reset" | "verify" | "pending" | "restorationError" | "adminDenied" | "products" | "settings";
const sessionRestoreTimeoutMs = 15_000;

function withSessionRestoreTimeout<T>(operation: Promise<T>): Promise<T> {
  let timer = 0;
  return Promise.race([
    operation,
    new Promise<T>((_, reject) => {
      timer = window.setTimeout(() => reject(new Error("Session restoration timed out.")), sessionRestoreTimeoutMs);
    })
  ]).finally(() => window.clearTimeout(timer));
}

export function App() {
  const [view, setView] = useState<View>(() => window.location.pathname === "/reset-password" ? "reset" : "loading");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [adminWorkspace, setAdminWorkspace] = useState<WorkspaceSummary | null>(null);
  const [currentWorkspace, setCurrentWorkspace] = useState<WorkspaceSummary | null>(null);
  const [firstName, setFirstName] = useState<string | null>(null);
  const [currentTime, setCurrentTime] = useState(() => new Date());
  const [resetToken, setResetToken] = useState<string | null>(() =>
    window.location.pathname === "/reset-password"
      ? new URLSearchParams(window.location.search).get("token")
      : null
  );
  const sessionRequest = useRef(0);
  const showGlobalHeader = ["pending", "adminDenied", "products", "settings"].includes(view);

  useEffect(() => {
    const interval = window.setInterval(() => setCurrentTime(new Date()), 60_000);
    return () => window.clearInterval(interval);
  }, []);

  const refreshSession = useCallback(async (showLoading = true) => {
    const requestNumber = ++sessionRequest.current;
    if (showLoading) setView("loading");
    setMessage("");
    if (!authClient) {
      setMessage(messages.configurationError);
      setView("restorationError");
      return;
    }

    try {
      const result = await withSessionRestoreTimeout(authClient.getSession());
      if (requestNumber !== sessionRequest.current) return;
      const token = result.data?.session?.token;
      if (result.error) {
        setMessage(messages.networkError);
        setView("restorationError");
        return;
      }
      if (!result.data?.session) {
        setAdminWorkspace(null);
        setCurrentWorkspace(null);
        setFirstName(null);
        window.history.replaceState(null, "", "/");
        setView("login");
        return;
      }
      setFirstName(getFirstName(result.data.user?.name, result.data.user?.email));
      if (!token) {
        setMessage(messages.networkError);
        setView("restorationError");
        return;
      }

      const access = await withSessionRestoreTimeout(checkWorkspaceAccess(token));
      if (requestNumber !== sessionRequest.current) return;
      if (access === "pending") {
        setAdminWorkspace(null);
        setCurrentWorkspace(null);
        setView("pending");
      } else if (access === "authorized") {
        const workspaces = await withSessionRestoreTimeout(listMyWorkspaces(token));
        if (requestNumber !== sessionRequest.current) return;
        const admin = workspaces.find((workspace) => workspace.role === "admin") ?? null;
        setAdminWorkspace(admin);
        setCurrentWorkspace(workspaces[0] ?? null);
        const pathname = window.location.pathname;
        if (pathname === "/administracao") {
          if (admin) {
            window.history.replaceState(null, "", "/configuracoes");
            setView("settings");
          } else setView("adminDenied");
        } else if (pathname.startsWith("/configuracoes")) setView("settings");
        else if (workspaces.length > 0) {
          if (!pathname.startsWith("/produtos")) window.history.replaceState(null, "", "/produtos");
          setView("products");
        } else setView("pending");
      } else if (access === "expired") {
        setMessage(messages.sessionError);
        setView("restorationError");
      } else {
        setMessage(messages.networkError);
        setView("restorationError");
      }
    } catch {
      if (requestNumber !== sessionRequest.current) return;
      sessionRequest.current++;
      setMessage(messages.networkError);
      setView("restorationError");
    }
  }, []);

  useEffect(() => {
    if (window.location.pathname === "/reset-password") {
      window.history.replaceState(null, "", "/reset-password");
      return;
    }

    let active = true;
    const requestVersion = sessionRequest;
    queueMicrotask(() => { if (active) void refreshSession(); });
    const handleFocus = () => void refreshSession(false);
    window.addEventListener("focus", handleFocus);
    return () => {
      active = false;
      requestVersion.current++;
      window.removeEventListener("focus", handleFocus);
    };
  }, [refreshSession]);

  async function signIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!authClient) return;
    setBusy(true);
    setMessage("");
    try {
      const result = await authClient.signIn.email({ email, password });
      setPassword("");
      if (result.error) {
        setMessage(messages.loginError);
      } else {
        await refreshSession();
      }
    } catch {
      setMessage(messages.loginError);
    } finally {
      setBusy(false);
    }
  }

  async function signOut() {
    if (!authClient) return;
    sessionRequest.current++;
    setBusy(true);
    setMessage("");
    try {
      const result = await authClient.signOut();
      if (result.error) {
        setMessage(messages.networkError);
      } else {
        setAdminWorkspace(null);
        setCurrentWorkspace(null);
        setFirstName(null);
        window.history.replaceState(null, "", "/");
        setView("login");
      }
    } catch {
      setMessage(messages.networkError);
    } finally {
      setBusy(false);
    }
  }

  async function requestRecovery(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!authClient) return;
    setBusy(true);
    setMessage("");
    try {
      const result = await authClient.requestPasswordReset({
        email,
        redirectTo: `${window.location.origin}/reset-password`
      });
      setMessage(result.error ? messages.recoveryError : messages.recoverySent);
    } catch {
      setMessage(messages.recoveryError);
    } finally {
      setBusy(false);
    }
  }

  async function resetPassword(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!authClient || !resetToken) return;
    setBusy(true);
    setMessage("");
    try {
      const result = await authClient.resetPassword({ newPassword: password, token: resetToken });
      setPassword("");
      if (result.error) {
        setMessage(messages.resetError);
      } else {
        setResetToken(null);
        window.history.replaceState(null, "", "/");
        setView("login");
        setMessage(messages.resetSuccess);
      }
    } catch {
      setMessage(messages.resetError);
    } finally {
      setBusy(false);
    }
  }

  async function sendVerificationCode() {
    if (!authClient || !email) return;
    setBusy(true);
    setMessage("");
    try {
      const sent = await sendEmailVerificationCode(email);
      setMessage(sent ? messages.verificationSent : messages.verificationError);
    } catch {
      setMessage(messages.verificationError);
    } finally {
      setBusy(false);
    }
  }

  async function verifyEmail(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!authClient) return;
    setBusy(true);
    setMessage("");
    try {
      const verified = await verifyEmailCode(email, code);
      if (!verified) {
        setMessage(messages.verificationError);
      } else {
        setCode("");
        setView("login");
        setMessage(messages.verificationSuccess);
      }
    } catch {
      setMessage(messages.verificationError);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="jl-app" data-theme="light">
      {showGlobalHeader && (
        <header className="global-header">
          <div className="global-header__brand">
            <img src="/brand/jlproject-logo.svg" alt={messages.applicationName} />
            <span>{messages.headerSubtitle}</span>
          </div>
          <p className="global-header__greeting">
            {getGreeting(firstName ?? messages.greetingFallbackName, currentTime)}
          </p>
          <nav className="global-header__actions" aria-label={messages.headerActions}>
            <button
              className="global-header__action"
              type="button"
              aria-label={messages.settings}
              aria-current={view === "settings" ? "page" : undefined}
              onClick={() => {
                window.history.pushState(null, "", "/configuracoes");
                setView("settings");
              }}
            >
              {messages.settings}
            </button>
            <button
              className="global-header__action global-header__action--unavailable"
              type="button"
              disabled
              title={messages.featureNotAvailable}
              aria-label={messages.devloop}
              aria-describedby="header-feature-not-available"
            >
              {messages.devloop}
            </button>
            <button
              className="global-header__action global-header__logout"
              type="button"
              disabled={busy}
              onClick={() => void signOut()}
            >
              {busy ? messages.signingOut : messages.signOutLabel}
            </button>
            <span id="header-feature-not-available" className="visually-hidden">
              {messages.featureNotAvailable}
            </span>
          </nav>
        </header>
      )}
      <main
        className={`application-shell${showGlobalHeader ? " application-shell--authenticated" : ""}${view === "login" ? " application-shell--login" : ""}`}
        aria-labelledby="application-title"
      >
      <section className={`application-card${view === "login" ? " application-card--login" : ""}`}>
        {showGlobalHeader ? (
          <h1 id="application-title" className="visually-hidden">{messages.applicationName}</h1>
        ) : view === "login" ? (
          <>
            <div className="login-branding">
              <img src="/brand/jlproject-logo.svg" alt={messages.applicationName} />
              <p>{messages.headerSubtitle}</p>
            </div>
            <h1 id="application-title">{messages.applicationSubtitle}</h1>
            <p className="application-status">{messages.applicationStatus}</p>
          </>
        ) : (
          <>
            <p className="application-brand">{messages.applicationName}</p>
            <h1 id="application-title">{messages.applicationSubtitle}</h1>
            <p className="application-status">{messages.applicationStatus}</p>
          </>
        )}

        {view === "loading" && <p role="status">{messages.loading}</p>}

        {view === "restorationError" && (
          <>
            <h2>{messages.sessionCheckTitle}</h2>
            <button type="button" onClick={() => void refreshSession()}>{messages.retry}</button>
            <button className="back-button" type="button" disabled={busy || !authClient} onClick={() => void signOut()}>{messages.signOut}</button>
          </>
        )}

        {view === "login" && (
          <>
            <h2>{messages.loginTitle}</h2>
            <form onSubmit={(event) => void signIn(event)}>
              <label htmlFor="email">{messages.email}</label>
              <input id="email" type="email" autoComplete="username" required value={email} onChange={(event) => setEmail(event.target.value)} />
              <label htmlFor="password">{messages.password}</label>
              <input id="password" type="password" autoComplete="current-password" required value={password} onChange={(event) => setPassword(event.target.value)} />
              <button type="submit" disabled={busy || !authClient}>{busy ? messages.signingIn : messages.signIn}</button>
            </form>
            <div className="secondary-actions">
              <button type="button" onClick={() => { setMessage(""); setView("recovery"); }}>{messages.forgotPassword}</button>
              <button type="button" onClick={() => { setMessage(""); setView("verify"); }}>{messages.verifyEmail}</button>
            </div>
          </>
        )}

        {view === "recovery" && (
          <>
            <h2>{messages.recoveryTitle}</h2>
            <form onSubmit={(event) => void requestRecovery(event)}>
              <label htmlFor="recovery-email">{messages.email}</label>
              <input id="recovery-email" type="email" autoComplete="email" required value={email} onChange={(event) => setEmail(event.target.value)} />
              <button type="submit" disabled={busy || !authClient}>{messages.recoveryButton}</button>
            </form>
            <button className="back-button" type="button" onClick={() => { setMessage(""); setView("login"); }}>{messages.backToLogin}</button>
          </>
        )}

        {view === "reset" && (
          <>
            <h2>{messages.resetTitle}</h2>
            {resetToken ? (
              <form onSubmit={(event) => void resetPassword(event)}>
                <label htmlFor="new-password">{messages.newPassword}</label>
                <input id="new-password" type="password" autoComplete="new-password" minLength={8} required value={password} onChange={(event) => setPassword(event.target.value)} />
                <button type="submit" disabled={busy || !authClient}>{messages.resetButton}</button>
              </form>
            ) : <p role="alert">{messages.invalidResetLink}</p>}
            <button className="back-button" type="button" onClick={() => { setResetToken(null); window.history.replaceState(null, "", "/"); setView("login"); }}>{messages.backToLogin}</button>
          </>
        )}

        {view === "verify" && (
          <>
            <h2>{messages.verificationTitle}</h2>
            <form onSubmit={(event) => void verifyEmail(event)}>
              <label htmlFor="verification-email">{messages.email}</label>
              <input id="verification-email" type="email" autoComplete="email" required value={email} onChange={(event) => setEmail(event.target.value)} />
              <label htmlFor="verification-code">{messages.verificationCode}</label>
              <input id="verification-code" type="text" inputMode="numeric" autoComplete="one-time-code" required value={code} onChange={(event) => setCode(event.target.value)} />
              <button type="submit" disabled={busy || !authClient}>{messages.confirmVerification}</button>
            </form>
            <button className="back-button" type="button" disabled={busy || !email} onClick={() => void sendVerificationCode()}>{messages.sendVerificationCode}</button>
            <button className="back-button" type="button" onClick={() => { setMessage(""); setView("login"); }}>{messages.backToLogin}</button>
          </>
        )}

        {view === "products" && currentWorkspace && (
          <Products workspace={currentWorkspace} onAccessLost={refreshSession} />
        )}
        {view === "settings" && (
          <Settings adminWorkspace={adminWorkspace} onAccessLost={refreshSession} onBack={() => {
            if (!currentWorkspace) {
              window.history.replaceState(null, "", "/");
              setView("pending");
              return;
            }
            window.history.pushState(null, "", "/produtos");
            setView("products");
          }} />
        )}
        {view === "adminDenied" && (
          <>
            <h2>{messages.accessDenied}</h2>
            <button type="button" onClick={() => {
              if (currentWorkspace) {
                window.history.pushState(null, "", "/produtos");
                setView("products");
              } else setView("pending");
            }}>{messages.back}</button>
          </>
        )}
        {view === "pending" && (
          <>
            <h2>{messages.accessPendingTitle}</h2>
            <p>{messages.accessPendingBody}</p>
          </>
        )}

        {message && <p className="feedback" role="alert">{message}</p>}
      </section>
      </main>
    </div>
  );
}
