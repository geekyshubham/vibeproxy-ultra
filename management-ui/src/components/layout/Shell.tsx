/* ============================================================================
   Shell — the authenticated layout frame. Sticky TopBar + TabBar, an offline
   banner when the backend drops, and the routed tab in an animated panel.
   ========================================================================== */
import { Outlet } from 'react-router-dom';
import TopBar from './TopBar';
import TabBar from './TabBar';
import OfflineBanner from './OfflineBanner';
import { useOnline } from '../../context/OnlineContext';

export default function Shell() {
  const { online } = useOnline();
  return (
    <div className="shell">
      <TopBar />
      <TabBar />
      {!online && <OfflineBanner />}
      <main className="tabpanel" role="tabpanel">
        <Outlet />
      </main>
    </div>
  );
}
