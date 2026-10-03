/**
 * Brute-force guard for the operator consent form. Same policy as the daemon's
 * FailGuard (docs/DASHBOARD_AUTH_MCP.md): 8 failures per IP within 15 minutes lock
 * that IP out for 15 minutes, and at most 60 submissions per minute are admitted
 * across all IPs. In-process only (resets on restart); rate-limit at the edge too.
 */
export class FailLimiter {
  constructor({
    maxFails = 8,
    windowMs = 15 * 60_000,
    lockMs = 15 * 60_000,
    floodPerMinute = 60,
    maxKeys = 10_000,
    now = Date.now,
  } = {}) {
    Object.assign(this, { maxFails, windowMs, lockMs, floodPerMinute, maxKeys, now });
    this.slots = new Map(); // key -> { fails, first, lockedUntil }; insertion order = recency
    this.recent = []; // timestamps of admitted attempts in the last minute (<= floodPerMinute)
  }

  /** Seconds to wait before trying again, or 0 when this attempt may proceed. */
  gate(key) {
    const t = this.now();
    const slot = this.slots.get(key);
    if (slot && slot.lockedUntil > t) return Math.ceil((slot.lockedUntil - t) / 1000);
    while (this.recent.length && t - this.recent[0] >= 60_000) this.recent.shift();
    if (this.recent.length >= this.floodPerMinute) {
      return Math.max(1, Math.ceil((60_000 - (t - this.recent[0])) / 1000));
    }
    this.recent.push(t);
    return 0;
  }

  fail(key) {
    const t = this.now();
    let slot = this.slots.get(key);
    if (!slot || t - slot.first >= this.windowMs) slot = { fails: 0, first: t, lockedUntil: 0 };
    slot.fails += 1;
    if (slot.fails >= this.maxFails) slot.lockedUntil = t + this.lockMs;
    this.slots.delete(key);
    this.slots.set(key, slot);
    if (this.slots.size > this.maxKeys) this.slots.delete(this.slots.keys().next().value);
  }

  clear(key) {
    this.slots.delete(key);
  }
}
