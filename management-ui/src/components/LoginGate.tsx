/* ============================================================================
   LoginGate — the unauthenticated screen. Accepts the management secret key and
   validates it via AuthContext.login (which probes GET /config). Errors render
   inline; the VibeProxy glyph is the hero mark.
   ========================================================================== */
import { useState, type FormEvent } from 'react';
import { useAuth } from '../context/AuthContext';
import { AuthError, NetworkError, hostLabel } from '../lib/apiClient';
import { BrandMark } from './BrandMark';

export default function LoginGate() {
  const { login } = useAuth();
  const [value, setValue] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!value.trim() || busy) return;
    setBusy(true);
    setError('');
    try {
      await login(value);
    } catch (err) {
      if (err instanceof AuthError) setError('That key was rejected. Check it and try again.');
      else if (err instanceof NetworkError) setError('Backend unreachable. Is the proxy running?');
      else setError('Something went wrong. Try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="gate">
      <form className="gate-card glass-panel" onSubmit={submit}>
        <div className="gate-logo">
          <BrandMark size={26} />
        </div>
        <h1>VibeProxy Ultra</h1>
        <p className="lede">Enter your management key to open the console.</p>

        <div className="field">
          <label htmlFor="mgmt-key">Management key</label>
          <input
            id="mgmt-key"
            className="inp mono"
            type="password"
            autoComplete="current-password"
            placeholder="vibeproxy-admin"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            autoFocus
          />
        </div>

        <div className="err" role="alert">
          {error}
        </div>

        <button className="btn btn-primary" type="submit" disabled={busy || !value.trim()}>
          {busy ? 'Checking…' : 'Unlock console'}
        </button>

        <div className="gate-foot">
          backend <span className="mono">{hostLabel()}</span>
        </div>
      </form>
    </div>
  );
}
