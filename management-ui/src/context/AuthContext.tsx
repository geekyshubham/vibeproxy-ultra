/* ============================================================================
   AuthContext — holds the management Bearer key (sessionStorage 'vp_mgmt_key').
   On mount it runs a boot probe: if a stored key validates against GET /config,
   we're authenticated; otherwise the LoginGate is shown. The apiClient reads
   the key via a registered getter so it never imports React context.
   ========================================================================== */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import apiClient, {
  AuthError,
  NetworkError,
  registerKeyGetter,
  registerAuthErrorHandler,
} from '../lib/apiClient';
import { useOnline } from './OnlineContext';

const KEY_STORAGE = 'vp_mgmt_key';

interface AuthCtx {
  authenticated: boolean;
  booting: boolean;
  /** False when the backend has auth disabled for this caller, so no key is needed
   *  and controls like "Lock" are meaningless. */
  authRequired: boolean;
  key: string;
  login: (key: string) => Promise<void>;
  logout: () => void;
}

const Ctx = createContext<AuthCtx | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const { setOffline, setOnline } = useOnline();
  const [key, setKey] = useState<string>(() => sessionStorage.getItem(KEY_STORAGE) ?? '');
  const [authenticated, setAuthenticated] = useState(false);
  const [booting, setBooting] = useState(true);
  // Starts true so the gate is never dropped before the backend confirms it can be.
  const [authRequired, setAuthRequired] = useState(true);

  // Keep a ref so the apiClient getter always sees the latest key.
  const keyRef = useRef(key);
  keyRef.current = key;
  // Mirror `authenticated` in a ref so the auth-error handler can tell a real
  // mid-session 401 (key rotated/revoked → log out) apart from the expected
  // 401 during boot-probe/login validation (before authenticated flips true).
  const authenticatedRef = useRef(authenticated);
  authenticatedRef.current = authenticated;

  const validate = useCallback(
    async (candidate: string): Promise<boolean> => {
      keyRef.current = candidate;
      try {
        await apiClient.get('/config');
        setOnline();
        return true;
      } catch (err) {
        if (err instanceof AuthError) return false;
        // Network error: can't validate. Treat as offline but keep the key.
        setOffline();
        throw err;
      }
    },
    [setOffline, setOnline],
  );

  // Boot probe.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      // Ask whether a key is needed at all. /auth-mode sits outside the management
      // auth middleware precisely so this question is answerable without one —
      // probing an authenticated route with an empty key would count as a failed
      // attempt and self-ban this IP after five page loads.
      try {
        const mode = await apiClient.get<{ authRequired?: boolean }>('/auth-mode');
        if (cancelled) return;
        setOnline();
        if (mode?.authRequired === false) {
          // Auth is off and we are a local caller: go straight in, no key involved.
          setAuthRequired(false);
          setAuthenticated(true);
          setBooting(false);
          return;
        }
      } catch (err) {
        if (cancelled) return;
        if (err instanceof NetworkError) setOffline();
        // Fail closed on anything else too (404 on an older backend, 5xx, malformed
        // body): keep the gate up and fall through to the stored-key path below.
      }

      const stored = sessionStorage.getItem(KEY_STORAGE) ?? '';
      if (!stored) {
        if (!cancelled) setBooting(false);
        return;
      }
      try {
        const ok = await validate(stored);
        if (cancelled) return;
        if (ok) {
          setAuthenticated(true);
        } else {
          sessionStorage.removeItem(KEY_STORAGE);
          setKey('');
        }
      } catch {
        // Offline with a stored key — optimistically authenticate; queries will
        // surface the offline banner and retry.
        if (!cancelled) setAuthenticated(true);
      } finally {
        if (!cancelled) setBooting(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [validate]);

  const login = useCallback(
    async (candidate: string) => {
      const trimmed = candidate.trim();
      const ok = await validate(trimmed);
      if (!ok) throw new AuthError(401);
      sessionStorage.setItem(KEY_STORAGE, trimmed);
      setKey(trimmed);
      setAuthenticated(true);
    },
    [validate],
  );

  const logout = useCallback(() => {
    sessionStorage.removeItem(KEY_STORAGE);
    setKey('');
    setAuthenticated(false);
  }, []);

  // Wire the apiClient getters/handlers. The key getter always reads the latest
  // key; the auth-error handler only logs out once we're actually authenticated,
  // so a 401 during boot-probe/login validation doesn't bounce the LoginGate.
  useEffect(() => {
    registerKeyGetter(() => keyRef.current);
    registerAuthErrorHandler(() => {
      if (!authenticatedRef.current) return;
      // A 401/403 here is proof the server wants a key, even if /auth-mode said
      // otherwise at boot — the setting is togglable at runtime and the server
      // hot-reloads it. Restoring the gate is what lets the user supply one.
      setAuthRequired(true);
      logout();
    });
  }, [logout]);

  const value = useMemo(
    () => ({ authenticated, booting, authRequired, key, login, logout }),
    [authenticated, booting, authRequired, key, login, logout],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useAuth(): AuthCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
