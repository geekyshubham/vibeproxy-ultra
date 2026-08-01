/* ============================================================================
   Shell — the authenticated layout frame. Sticky TopBar + TabBar, an offline
   banner when the backend drops, and the routed tab in an animated panel.
   ========================================================================== */
import { Outlet } from 'react-router-dom';
import TopBar from './TopBar';
import TabBar from './TabBar';
import OfflineBanner from './OfflineBanner';
import { useOnline } from '../../context/OnlineContext';
import { UsageDayProvider } from '../../context/UsageDayContext';

export default function Shell() {
  const { online } = useOnline();
  return (
    // UsageDayProvider spans both the TopBar (which holds the date picker) and the
    // routed tab (which renders that day's breakdown), so the two stay in sync.
    <UsageDayProvider>
      <div className="shell">
        <TopBar />
        <TabBar />
        {!online && <OfflineBanner />}
        <main className="tabpanel" role="tabpanel">
          <Outlet />
        </main>
      </div>
    </UsageDayProvider>
  );
}
