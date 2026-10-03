import crypto from "node:crypto";

/** Constant-time string equality (hashing first hides length differences too). */
export function safeEqual(a, b) {
  const ha = crypto.createHash("sha256").update(String(a ?? "")).digest();
  const hb = crypto.createHash("sha256").update(String(b ?? "")).digest();
  return crypto.timingSafeEqual(ha, hb);
}

/** 256-bit URL-safe secret; the prefix makes leaked tokens recognisable to secret scanners. */
export function randomToken(prefix = "") {
  return prefix + crypto.randomBytes(32).toString("base64url");
}
