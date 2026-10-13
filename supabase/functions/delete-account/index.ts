// Phase 6.0.5 — Account Deletion. Permanently deletes the calling user's Supabase Auth account
// (and, via `profiles` → CASCADE, every `budgets`/`categories`/`head_categories`/`wallets`/
// `entries` row they own) plus their `avatars` Storage object. Must run server-side: deleting an
// `auth.users` row requires the service-role key, which must never ship in the iOS app.
//
// Identity is derived ONLY from the caller's own JWT (forwarded `Authorization` header) via
// `userClient.auth.getUser()` — the request body is never trusted for anything; this function
// takes no body at all.
//
// Reauthentication history (read in order if touching this again):
//
// v1 consumed a `reauthenticate()` email-OTP nonce by rotating the caller's password to a random,
// discarded value. GoTrue's source showed that path only validates a nonce on the password-update
// endpoint, gated by a project setting with a hardcoded 24-hour session-age exemption — unsound.
//
// v2 required the caller's current password in the request body and verified it here via
// `signInWithPassword`. That IS a real, unconditional verification, but putting the password in
// this function's OWN request body means it lands in the Supabase Dashboard's Edge Functions
// "Invocations" log, which captures full request bodies by default (confirmed directly from
// Supabase's docs: "Invocations include: Request/Response data including headers, body, status
// codes" — no documented redaction or opt-out exists). A plaintext password sitting in a
// retained log is an unnecessary exposure.
//
// v3 (this version) moves password verification entirely to the client, using the exact same
// `SupabaseAuthService.signIn(email:password:)` GoTrue endpoint `ChangePasswordView` already uses
// — so the password only ever transits the same path every ordinary sign-in already does, not a
// custom function's logged body. A successful `signIn` call updates `auth.users.last_sign_in_at`
// (confirmed by reading `supabase/auth`'s `internal/tokens/service.go`: `IssueRefreshToken` sets
// it on every genuine credential grant) — but, critically, a plain refresh-token grant does
// *not* touch it (`internal/api/token_refresh.go`'s `RefreshTokenGrant` never calls
// `UpdateLastSignInAt`). That makes `last_sign_in_at`, fetched here via the Admin API
// (`admin.getUserById`, never trusting anything the client supplies), a genuine, server-only,
// unspoofable "when did this user last actually present a credential" signal — the `auth_time`
// equivalent the standard access-token JWT doesn't carry (that claim only exists on the OIDC
// `id_token`, which plain email/password sign-in never issues). This function rejects deletion
// unless that timestamp is within `MAX_AUTH_AGE_SECONDS` of now.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const AVATAR_CLEANUP_ATTEMPTS = 3;
const AVATAR_CLEANUP_RETRY_DELAY_MS = 500;

// Generous enough to cover normal network latency between the client's `signIn` call and this
// function's own invocation (two sequential round trips), tight enough that it can only be
// satisfied by a password just presented, not a session that merely happens to be open.
const MAX_AUTH_AGE_SECONDS = 120;

type ErrorCode =
  | "unauthenticated"
  | "user_not_found"
  | "reauthentication_required"
  | "wallet_conflict"
  | "delete_failed";

function jsonError(code: ErrorCode, status: number, message: string) {
  return new Response(JSON.stringify({ error: code, message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function jsonSuccess(avatarCleanupFailed: boolean) {
  return new Response(JSON.stringify({ success: true, avatarCleanupFailed }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/// Best-effort, bounded retries — the account is already gone by the time this runs, so there is
/// no session to lose and nothing unsafe about trying again. A failure after every attempt is
/// reported honestly via `avatarCleanupFailed` rather than silently swallowed.
///
/// This is NOT merely a storage-hygiene nit: the `avatars` bucket is public for reads (so
/// `getPublicURL` works without signed URLs), and that public read access has no RLS tie to
/// `auth.uid()` at all — only writes/deletes are owner-gated. A blob this retry loop can't remove
/// stays publicly viewable at its stable URL indefinitely, even though the account (and the photo
/// owner's ability to ever remove it themselves) is gone. `avatarCleanupFailed: true` is the only
/// signal that this happened; the caller must not discard it. A real fix for a leftover blob needs
/// an out-of-band sweep (e.g. a scheduled function diffing the `avatars` bucket against
/// `auth.users`) or manual removal via the Dashboard once this function's logs flag it — not
/// implemented here.
async function removeAvatarWithRetries(
  // deno-lint-ignore no-explicit-any
  adminClient: any,
  avatarPath: string,
): Promise<boolean> {
  for (let attempt = 1; attempt <= AVATAR_CLEANUP_ATTEMPTS; attempt++) {
    const { error } = await adminClient.storage.from("avatars").remove([avatarPath]);
    if (!error) return true;
    console.error(
      `delete-account: avatar cleanup attempt ${attempt}/${AVATAR_CLEANUP_ATTEMPTS} failed for ${avatarPath}: ${error.message}`,
    );
    if (attempt < AVATAR_CLEANUP_ATTEMPTS) {
      await sleep(AVATAR_CLEANUP_RETRY_DELAY_MS);
    }
  }
  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonError("delete_failed", 405, "Method not allowed.");
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonError("unauthenticated", 401, "Missing Authorization header.");
  }

  // Scoped to the caller's own JWT — RLS-respecting, and the only source of truth for identity.
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });

  const { data: userData, error: getUserError } = await userClient.auth.getUser();
  if (getUserError || !userData?.user) {
    // GoTrue's own `requireAuthentication` middleware (confirmed by reading
    // `supabase/auth`'s `internal/api/auth.go`) returns a *distinct* error code depending on
    // exactly what's wrong — and these are NOT interchangeable:
    //   - "user_not_found": the JWT's signature and session are both fine, but the `sub` claim's
    //     user row no longer exists. This is the one case that plausibly means "this is a retried
    //     call after a prior invocation's `deleteUser` already succeeded but its response was
    //     lost" — the only outcome the iOS client is allowed to treat as "may already be deleted"
    //     and proceed to local cleanup + sign-out.
    //   - "bad_jwt" (expired/malformed/tampered signature) or "session_not_found" (session row
    //     revoked, e.g. signed out elsewhere) — both mean the request is simply unauthenticated
    //     for reasons that have nothing to do with this account having been deleted. Collapsing
    //     these into the same bucket as "user_not_found" would let a plain expired or revoked
    //     session be mistaken for confirmed (or even possible) deletion, which would wipe a
    //     perfectly intact account's local data for no reason. They get the plain
    //     `unauthenticated` code instead, which the client never treats as ambiguous.
    const code = (getUserError as { code?: string } | null)?.code;
    if (code === "user_not_found") {
      return jsonError("user_not_found", 401, "Not authenticated.");
    }
    return jsonError("unauthenticated", 401, "Not authenticated.");
  }
  const userId = userData.user.id;

  // Privileged client for everything past this point — never built from request input.
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // The actual reauthentication check — see the module doc comment for why `last_sign_in_at`
  // (fetched here, server-side, via the Admin API — never trusting a client-supplied timestamp
  // or treating "has a valid JWT" alone as sufficient) is the right signal.
  const { data: adminUserData, error: adminUserError } = await adminClient.auth.admin.getUserById(
    userId,
  );
  if (adminUserError || !adminUserData?.user) {
    return jsonError("delete_failed", 500, adminUserError?.message ?? "Could not verify account.");
  }
  const lastSignInAt = adminUserData.user.last_sign_in_at
    ? new Date(adminUserData.user.last_sign_in_at)
    : null;
  if (!lastSignInAt || (Date.now() - lastSignInAt.getTime()) / 1000 > MAX_AUTH_AGE_SECONDS) {
    return jsonError(
      "reauthentication_required",
      401,
      "Please sign in again, then retry deleting your account.",
    );
  }

  // Defensive RESTRICT guard: `entries.wallet_id`/`destination_wallet_id` → `wallets.id` is
  // RESTRICT. Today every wallet/entry pair is scoped to a single `user_id` (no cross-user
  // wallet sharing in this schema), so this should never fire — kept as a safety net against a
  // raw, confusing Postgres FK-violation error if that ever changes, rather than a required step.
  const { data: ownWallets, error: walletsError } = await adminClient
    .from("wallets")
    .select("id")
    .eq("user_id", userId);
  if (walletsError) {
    return jsonError("delete_failed", 500, walletsError.message);
  }
  const walletIds = (ownWallets ?? []).map((w: { id: string }) => w.id);
  if (walletIds.length > 0) {
    const { count, error: conflictError } = await adminClient
      .from("entries")
      .select("id", { count: "exact", head: true })
      .neq("user_id", userId)
      .or(
        `wallet_id.in.(${walletIds.join(",")}),destination_wallet_id.in.(${walletIds.join(",")})`,
      );
    if (conflictError) {
      return jsonError("delete_failed", 500, conflictError.message);
    }
    if ((count ?? 0) > 0) {
      return jsonError(
        "wallet_conflict",
        409,
        "Another account has transactions linked to one of your wallets. Remove that link before deleting your account.",
      );
    }
  }

  // The irreversible step, done BEFORE avatar cleanup on purpose: it depends only on the
  // service-role key, never on the caller's own session, so doing it first means a slow/flaky
  // Storage call can never block or risk the actual account deletion. `profiles` cascades to
  // budgets/categories/head_categories/wallets/entries; entries also cascades directly off
  // `profiles` so Postgres's cascade resolution deletes it before/with wallets, satisfying the
  // RESTRICT constraint without manual ordering.
  const { error: deleteError } = await adminClient.auth.admin.deleteUser(userId);
  if (deleteError) {
    // Never report success unless this specific call actually succeeded.
    return jsonError("delete_failed", 500, deleteError.message);
  }

  // Storage cleanup after the point of no return — safe to retry here since it only needs the
  // service-role key, not the (now-deleted) user's session. See `removeAvatarWithRetries` doc
  // comment for what happens — and why it's safe — if every attempt still fails.
  const avatarPath = `${userId.toLowerCase()}/avatar.jpg`;
  const avatarCleanupSucceeded = await removeAvatarWithRetries(adminClient, avatarPath);

  return jsonSuccess(!avatarCleanupSucceeded);
});
