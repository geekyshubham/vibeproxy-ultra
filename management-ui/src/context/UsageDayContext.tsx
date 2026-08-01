/* ============================================================================
   UsageDayContext — which calendar day the usage views are reporting on.

   Lives in context because the control and the readout are deliberately in
   different places: the date picker sits in the TopBar (reachable from every
   tab) while the breakdown renders inside the Overview tab. This mirrors
   UsageStore.selectedDay on the macOS side, so both surfaces express "the
   selected day" the same way.

   Days are plain 'YYYY-MM-DD' strings in the *local* timezone — never Date
   objects — because that is exactly the key format the macOS app writes and the
   server reads. Round-tripping through UTC here would shift the day for anyone
   not on UTC.
   ========================================================================== */
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { todayKey } from '../lib/format';

interface UsageDayCtx {
  /** The selected day as 'YYYY-MM-DD'. */
  day: string;
  setDay: (day: string) => void;
  /** Jump back to today. */
  resetToToday: () => void;
  isToday: boolean;
}

const Ctx = createContext<UsageDayCtx | null>(null);

export function UsageDayProvider({ children }: { children: ReactNode }) {
  const [day, setDayState] = useState<string>(() => todayKey());
  // What "today" currently is, as state rather than a bare todayKey() call.
  // A dashboard is routinely left open overnight: with today's key captured once,
  // `isToday` stays true for yesterday after midnight, so the "Today" button —
  // the only control that gets the user back — stays hidden on a stale day.
  const [today, setToday] = useState<string>(() => todayKey());

  useEffect(() => {
    // Re-arm on each rollover rather than polling, and schedule from the actual
    // clock so DST shifts and machine sleep can't accumulate drift. The +1s pad
    // keeps a slightly-early timer from landing back on the same day.
    let timer: ReturnType<typeof setTimeout>;
    const scheduleNextMidnight = () => {
      const now = new Date();
      const midnight = new Date(now);
      midnight.setHours(24, 0, 0, 0);
      timer = setTimeout(() => {
        setToday(todayKey());
        scheduleNextMidnight();
      }, midnight.getTime() - now.getTime() + 1000);
    };
    scheduleNextMidnight();
    return () => clearTimeout(timer);
  }, []);

  const setDay = useCallback((next: string) => {
    // A cleared native date input reports ''. Treat that as "back to today"
    // rather than querying an empty date, which the server would reject.
    setDayState(next || todayKey());
  }, []);

  const resetToToday = useCallback(() => {
    const key = todayKey();
    setToday(key);
    setDayState(key);
  }, []);

  const value = useMemo(
    () => ({ day, setDay, resetToToday, isToday: day === today }),
    [day, today, setDay, resetToToday],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useUsageDay(): UsageDayCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useUsageDay must be used within UsageDayProvider');
  return ctx;
}
