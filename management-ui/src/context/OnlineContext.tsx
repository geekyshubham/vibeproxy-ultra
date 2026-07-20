/* ============================================================================
   OnlineContext — tracks whether the backend is reachable. The apiClient throws
   NetworkError on fetch failure; queries flip this to offline so the shell can
   show the OfflineBanner. Any successful request flips it back online.
   ========================================================================== */
import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react';

interface OnlineCtx {
  online: boolean;
  setOffline: () => void;
  setOnline: () => void;
}

const Ctx = createContext<OnlineCtx | null>(null);

export function OnlineProvider({ children }: { children: ReactNode }) {
  const [online, setOnlineState] = useState(true);
  const setOffline = useCallback(() => setOnlineState(false), []);
  const setOnline = useCallback(() => setOnlineState(true), []);
  const value = useMemo(() => ({ online, setOffline, setOnline }), [online, setOffline, setOnline]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useOnline(): OnlineCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useOnline must be used within OnlineProvider');
  return ctx;
}
