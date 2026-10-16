// Renders the password-recovery landing page. Sets the new password entirely in-browser via
// GoTrue's REST API (the same endpoints `supabase-swift` itself calls) — no PKCE `code` exchange,
// since that requires the code verifier `resetPasswordForEmail` stashes in the *app's* Keychain,
// which no browser can ever reach. `token_hash`/`type` arrive straight from the email link
// (Dashboard's Reset Password template points here with `{{ .TokenHash }}`) and are verified
// client-side via `POST /auth/v1/verify` into a short-lived access token used only to call
// `PUT /auth/v1/user` with the new password. Works identically on any device/browser, logged into
// the app or not — the whole point of moving off the custom-URL-scheme-only redirect this replaced.

// Mirrors `FinanceTracker/Config/SupabaseConfig.swift` — the anon/publishable key is meant to be
// public and already ships inside the iOS app itself; duplicating it here is not a new exposure.
const SUPABASE_URL = "https://coktoiawbuxxgehnahhl.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_gWkVcOu61yLwgLzez2IVhQ_e9TgFNiS";
const MIN_PASSWORD_LENGTH = 8;

export type RenderOptions =
  | { mode: "verify"; tokenHash: string; type: string }
  // See `index.ts`'s doc comment — only reachable from emails sent before the template switched
  // to `token_hash` links. Can't be completed in a browser at all, so this just offers the same
  // "open the app" bridge the page used to be exclusively.
  | { mode: "legacyDeepLink"; deepLink: string }
  | { mode: "error"; message: string | null };

function escapeHTML(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function renderHTML(options: RenderOptions): string {
  const bodyAndScript = (() => {
    switch (options.mode) {
      case "verify":
        return {
          body: verifyBody(),
          script: verifyScript(escapeHTML(options.tokenHash), escapeHTML(options.type)),
        };
      case "legacyDeepLink":
        return { body: legacyDeepLinkBody(escapeHTML(options.deepLink)), script: "" };
      case "error":
        return { body: errorBody(options.message ? escapeHTML(options.message) : null), script: "" };
    }
  })();

  return `<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="robots" content="noindex" />
<title>Clarity — Restablecer contraseña</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
    background: #0a0a0c;
    color: #ffffff;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  }
  .card {
    max-width: 420px;
    width: 100%;
    text-align: center;
    padding: 32px 24px;
    border-radius: 20px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }
  .icon { font-size: 40px; margin-bottom: 12px; }
  h1 { font-size: 20px; margin: 0 0 12px; }
  p.muted { color: rgba(255, 255, 255, 0.6); font-size: 15px; line-height: 1.5; margin: 0 0 20px; }
  form { text-align: left; }
  label { display: block; font-size: 13px; color: rgba(255, 255, 255, 0.6); margin: 16px 0 6px; }
  input {
    width: 100%;
    padding: 12px 14px;
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.06);
    color: #ffffff;
    font-size: 16px;
  }
  input:focus { outline: none; border-color: #0ea5e9; }
  .error { color: #ef4444; font-size: 14px; margin-top: 12px; min-height: 18px; }
  .button, a.button {
    display: block;
    width: 100%;
    margin-top: 24px;
    padding: 14px 28px;
    border-radius: 999px;
    border: none;
    text-decoration: none;
    font-weight: 600;
    font-size: 16px;
    color: #0a0a0c;
    background: linear-gradient(90deg, #10b981, #0ea5e9);
    cursor: pointer;
  }
  .button:disabled { opacity: 0.5; cursor: default; }
  .spinner {
    width: 28px;
    height: 28px;
    margin: 8px auto 20px;
    border-radius: 50%;
    border: 3px solid rgba(255, 255, 255, 0.15);
    border-top-color: #0ea5e9;
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  [hidden] { display: none !important; }
</style>
</head>
<body>
  <div class="card">
    ${bodyAndScript.body}
  </div>
  ${bodyAndScript.script}
</body>
</html>`;
}

function verifyBody(): string {
  return `
    <div id="state-verifying">
      <div class="spinner"></div>
      <p class="muted">Verificando tu enlace…</p>
    </div>

    <div id="state-error" hidden>
      <div class="icon">⚠️</div>
      <h1>Este enlace ya no es válido</h1>
      <p class="muted" id="error-message">El enlace expiró o ya fue usado.</p>
      <p class="muted">Volvé a Clarity y pedí uno nuevo desde "¿Olvidaste tu contraseña?".</p>
    </div>

    <div id="state-form" hidden>
      <div class="icon">🔐</div>
      <h1>Elegí tu nueva contraseña</h1>
      <form id="password-form">
        <label for="password">Nueva contraseña</label>
        <input id="password" type="password" autocomplete="new-password" minlength="${MIN_PASSWORD_LENGTH}" required />
        <label for="confirm">Confirmá la contraseña</label>
        <input id="confirm" type="password" autocomplete="new-password" minlength="${MIN_PASSWORD_LENGTH}" required />
        <p class="error" id="form-error"></p>
        <button class="button" id="submit-button" type="submit">Guardar contraseña</button>
      </form>
    </div>

    <div id="state-success" hidden>
      <div class="icon">✅</div>
      <h1>¡Listo!</h1>
      <p class="muted">Tu contraseña se actualizó. Ya podés volver a Clarity e iniciar sesión con tu nueva contraseña.</p>
    </div>
  `;
}

function verifyScript(safeTokenHash: string, safeType: string): string {
  return `
  <script>
    (function () {
      var SUPABASE_URL = ${JSON.stringify(SUPABASE_URL)};
      var SUPABASE_ANON_KEY = ${JSON.stringify(SUPABASE_ANON_KEY)};
      var MIN_PASSWORD_LENGTH = ${MIN_PASSWORD_LENGTH};
      var tokenHash = ${JSON.stringify(safeTokenHash)};
      var type = ${JSON.stringify(safeType)};
      var accessToken = null;

      function show(id) {
        ["state-verifying", "state-error", "state-form", "state-success"].forEach(function (s) {
          document.getElementById(s).hidden = s !== id;
        });
      }

      function showError(message) {
        document.getElementById("error-message").textContent = message;
        show("state-error");
      }

      fetch(SUPABASE_URL + "/auth/v1/verify", {
        method: "POST",
        headers: { "Content-Type": "application/json", apikey: SUPABASE_ANON_KEY },
        body: JSON.stringify({ type: type, token_hash: tokenHash }),
      })
        .then(function (res) {
          return res.json().then(function (data) {
            if (!res.ok || !data.access_token) {
              throw new Error(data.error_description || data.msg || "El enlace expiró o ya fue usado.");
            }
            accessToken = data.access_token;
            show("state-form");
          });
        })
        .catch(function (err) {
          showError(err.message || "El enlace expiró o ya fue usado.");
        });

      document.getElementById("password-form").addEventListener("submit", function (event) {
        event.preventDefault();
        var password = document.getElementById("password").value;
        var confirm = document.getElementById("confirm").value;
        var errorEl = document.getElementById("form-error");
        var button = document.getElementById("submit-button");
        errorEl.textContent = "";

        if (password.length < MIN_PASSWORD_LENGTH) {
          errorEl.textContent = "La contraseña debe tener al menos " + MIN_PASSWORD_LENGTH + " caracteres.";
          return;
        }
        if (password !== confirm) {
          errorEl.textContent = "Las contraseñas no coinciden.";
          return;
        }

        button.disabled = true;
        button.textContent = "Guardando…";

        fetch(SUPABASE_URL + "/auth/v1/user", {
          method: "PUT",
          headers: {
            "Content-Type": "application/json",
            apikey: SUPABASE_ANON_KEY,
            Authorization: "Bearer " + accessToken,
          },
          body: JSON.stringify({ password: password }),
        })
          .then(function (res) {
            return res.json().then(function (data) {
              if (!res.ok) {
                throw new Error(data.msg || data.error_description || "No pudimos actualizar tu contraseña.");
              }
              show("state-success");
            });
          })
          .catch(function (err) {
            errorEl.textContent = err.message || "No pudimos actualizar tu contraseña. Probá de nuevo.";
            button.disabled = false;
            button.textContent = "Guardar contraseña";
          });
      });
    })();
  </script>
  `;
}

function legacyDeepLinkBody(safeDeepLink: string): string {
  return `
    <div class="icon">🔐</div>
    <h1>Abrí este enlace desde tu iPhone</h1>
    <p class="muted">Este enlace es de un formato anterior que solo la app puede completar.</p>
    <a class="button" href="${safeDeepLink}">Abrir en Clarity</a>
    <p class="muted">Si no tenés la app instalada en este dispositivo, volvé a Clarity desde tu
      iPhone y pedí un enlace nuevo — los nuevos enlaces funcionan desde cualquier navegador.</p>
  `;
}

function errorBody(message: string | null): string {
  return `
    <div class="icon">⚠️</div>
    <h1>Este enlace ya no es válido</h1>
    <p class="muted">${message ?? "El enlace expiró o ya fue usado."}. Volvé a Clarity y pedí uno
      nuevo desde "¿Olvidaste tu contraseña?".</p>
  `;
}
