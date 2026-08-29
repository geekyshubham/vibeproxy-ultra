/* ============================================================================
   App — the auth gate switch. While the boot probe runs we show a minimal
   splash; unauthenticated → <LoginGate/>; else the routed console.
   The favicon (branded VibeRouter glyph on the accent chip) is a static
   <link> in index.html so it renders before React mounts.
   ========================================================================== */
import { RouterProvider } from 'react-router-dom';
import { useAuth } from './context/AuthContext';
import LoginGate from './components/LoginGate';
import { BrandMark } from './components/BrandMark';
import { router } from './router';

export default function App() {
  const { authenticated, booting } = useAuth();

  if (booting) {
    return (
      <div className="gate">
        <div className="gate-card glass-panel" aria-busy="true">
          <div className="gate-logo">
            <BrandMark />
          </div>
          <p className="lede">Connecting…</p>
        </div>
      </div>
    );
  }

  if (!authenticated) return <LoginGate />;

  return <RouterProvider router={router} />;
}
