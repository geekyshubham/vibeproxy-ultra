/* ============================================================================
   TopBar — sticky brand + status header (.topbar). Shows the VibeRouter glyph
   mark, the console title, the live backend host, the usage date picker, and a
   logout control.
   ========================================================================== */
import { useAuth } from '../../context/AuthContext';
import { useOnline } from '../../context/OnlineContext';
import { hostLabel } from '../../lib/apiClient';
import { BrandMark } from '../BrandMark';
import UsageDayPicker from '../UsageDayPicker';
import Icon from '../../lib/icons';

export default function TopBar() {
  const { logout, authRequired } = useAuth();
  const { online } = useOnline();

  return (
    <header className="topbar glass-panel">
      <div className="brand-mark">
        <BrandMark />
      </div>
      <div className="titles">
        <div className="t1">VibeRouter · Management</div>
        <div className="t2">
          <span className={`dot ${online ? 'ok pulse' : 'bad'}`} />
          <span>{online ? 'Connected' : 'Offline'}</span>
          <span>·</span>
          <span className="mono">{hostLabel()}</span>
        </div>
      </div>
      <div className="grow" />
      <UsageDayPicker />
      {/* With auth disabled there is no key to sign back in with, so offering
          "Lock" would strand the user at a gate they cannot pass. */}
      {authRequired && (
        <button className="btn btn-soft btn-sm" onClick={logout} title="Sign out">
          <Icon.Lock />
          <span>Lock</span>
        </button>
      )}
    </header>
  );
}
