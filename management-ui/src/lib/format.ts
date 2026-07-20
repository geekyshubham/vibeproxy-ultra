/* ============================================================================
   format — small pure display helpers. No React, no side effects.
   ========================================================================== */

/** Relative "time ago" for ISO timestamps; falls back to '—'. */
export function timeAgo(iso: string | undefined | null): string {
  if (!iso) return '—';
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return '—';
  const secs = Math.max(0, Math.floor((Date.now() - then) / 1000));
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

/** Human byte size. */
export function bytes(n: number | undefined | null): string {
  if (!n || n < 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
}

/** Mask a secret, showing only the last few chars. */
export function maskKey(key: string | undefined | null, tail = 4): string {
  if (!key) return '';
  if (key.length <= tail) return '••••';
  return `••••${key.slice(-tail)}`;
}

/** Compact integer with thousands separators. */
export function num(n: number | undefined | null): string {
  if (n == null || Number.isNaN(n)) return '0';
  return n.toLocaleString('en-US');
}
