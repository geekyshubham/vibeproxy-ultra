/* ============================================================================
   ToastContext — a single transient toast at the bottom center. Callers fire
   toast('Saved', 'ok'); it auto-dismisses. Kinds map to .toast.ok/.bad/.info.
   ========================================================================== */
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import Icon from '../lib/icons';

type ToastKind = 'ok' | 'bad' | 'info';
interface ToastState {
  msg: string;
  kind: ToastKind;
  id: number;
}
interface ToastCtx {
  toast: (msg: string, kind?: ToastKind) => void;
}

const Ctx = createContext<ToastCtx | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<ToastState | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const toast = useCallback((msg: string, kind: ToastKind = 'info') => {
    if (timer.current) clearTimeout(timer.current);
    setState({ msg, kind, id: Date.now() });
    timer.current = setTimeout(() => setState(null), 2600);
  }, []);

  // Clear any pending timer on unmount so it can't fire after teardown.
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  const value = useMemo(() => ({ toast }), [toast]);

  const KindIcon = state?.kind === 'ok' ? Icon.Check : state?.kind === 'bad' ? Icon.Alert : Icon.Info;

  return (
    <Ctx.Provider value={value}>
      {children}
      {state && (
        <div className={`toast glass ${state.kind}`} role="status" key={state.id}>
          <KindIcon />
          <span>{state.msg}</span>
        </div>
      )}
    </Ctx.Provider>
  );
}

export function useToast(): ToastCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useToast must be used within ToastProvider');
  return ctx;
}
