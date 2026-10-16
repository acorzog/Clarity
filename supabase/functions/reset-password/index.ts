// Password-recovery landing page — a real HTTPS URL so the emailed reset link always loads,
// regardless of device/browser/app-installed-or-not (see `page.ts`'s doc comment for why this
// exists and why it had to move off a bare PKCE `code` exchange).
//
// Reads `token_hash`/`type` straight off the query string — the email template (Supabase
// Dashboard → Authentication → Email Templates → Reset Password) links directly here with
// `{{ .TokenHash }}`, bypassing Supabase's own `/auth/v1/verify` redirect entirely. The page's own
// client-side JS (`page.ts`) does the `verifyOtp`/`updateUser` calls against GoTrue's REST API.
//
// `code`/`error_description` are handled too, purely for emails already sent before this template
// change — those still carry Supabase's old PKCE-redirect shape and can't be exchanged from a
// browser (the code verifier lives only in the app's Keychain), so they fall back to the
// deep-link bridge this page used to be exclusively. Safe to delete once those have all expired.
import { renderHTML } from "./page.ts";

const KNOWN_SCHEMES = new Set(["financetracker", "financetrackerdev"]);

Deno.serve((req: Request) => {
  const params = new URL(req.url).searchParams;

  const tokenHash = params.get("token_hash");
  if (tokenHash) {
    return respond(renderHTML({ mode: "verify", tokenHash, type: params.get("type") ?? "recovery" }));
  }

  const code = params.get("code");
  if (code) {
    const requestedScheme = params.get("scheme") ?? "financetracker";
    const scheme = KNOWN_SCHEMES.has(requestedScheme) ? requestedScheme : "financetracker";
    const deepLink = `${scheme}://reset-password?code=${encodeURIComponent(code)}`;
    return respond(renderHTML({ mode: "legacyDeepLink", deepLink }));
  }

  const errorDescription = params.get("error_description");
  return respond(
    renderHTML({ mode: "error", message: errorDescription?.replace(/\+/g, " ") ?? null }),
  );
});

function respond(html: string): Response {
  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8" } });
}
