/* ============================================================================
   OfflineBanner — shown when the backend is unreachable (.banner). Purely
   presentational; OnlineContext decides when to render it.
   ========================================================================== */
import Icon from '../../lib/icons';
import { hostLabel } from '../../lib/apiClient';

export default function OfflineBanner() {
  return (
    <div className="banner" role="status">
      <Icon.WifiOff />
      <span>
        Backend unreachable at <span className="mono">{hostLabel()}</span> — showing last known state.
        Start the proxy from the menu bar.
      </span>
    </div>
  );
}
