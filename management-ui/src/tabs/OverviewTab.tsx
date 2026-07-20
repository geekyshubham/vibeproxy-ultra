/* ============================================================================
   OverviewTab — at-a-glance stat tiles: accounts, api-keys, compat providers,
   logging state. Every collection is normalized via asArray/pluckArray so a
   null response renders "0" instead of crashing.
   ========================================================================== */
import { useManagementQuery } from '../lib/useManagementQuery';
import { pluckArray } from '../lib/apiClient';
import type { AuthFile, BackendConfig, CompatProvider } from '../lib/types';
import { num } from '../lib/format';
import Icon from '../lib/icons';
import LoadingBlock from '../components/LoadingBlock';

interface StatProps {
  Glyph: typeof Icon.Users;
  label: string;
  value: string;
  sub?: string;
  subOk?: boolean;
}

function Stat({ Glyph, label, value, sub, subOk }: StatProps) {
  return (
    <div className="stat glass">
      <div className="lbl">
        <Glyph />
        <span>{label}</span>
      </div>
      <div className="val">{value}</div>
      {sub && <div className={`sub ${subOk ? 'ok' : ''}`}>{sub}</div>}
    </div>
  );
}

export default function OverviewTab() {
  const cfg = useManagementQuery<BackendConfig>('/config');
  const authFiles = useManagementQuery<{ files: AuthFile[] | null }>('/auth-files');
  const compat = useManagementQuery<{ 'openai-compatibility': CompatProvider[] | null }>(
    '/openai-compatibility',
  );

  if (cfg.isLoading || authFiles.isLoading || compat.isLoading) {
    return (
      <section className="view">
        <LoadingBlock rows={2} height={92} />
      </section>
    );
  }

  const files = pluckArray<AuthFile>(authFiles.data, 'files');
  const enabledFiles = files.filter((f) => !f.disabled);
  const providers = pluckArray<CompatProvider>(compat.data, 'openai-compatibility');
  const enabledProviders = providers.filter((p) => !p.disabled);

  const apiKeys = pluckArray<string>(cfg.data, 'api-keys');
  const loggingOn = Boolean(cfg.data?.['logging-to-file']);

  return (
    <section className="view">
      <div className="grid g-stats">
        <Stat
          Glyph={Icon.Users}
          label="OAuth accounts"
          value={num(files.length)}
          sub={`${enabledFiles.length} active`}
          subOk={enabledFiles.length > 0}
        />
        <Stat
          Glyph={Icon.Key}
          label="Proxy API keys"
          value={num(apiKeys.length)}
          sub={apiKeys.length ? 'configured' : 'none set'}
          subOk={apiKeys.length > 0}
        />
        <Stat
          Glyph={Icon.Server}
          label="Compat providers"
          value={num(providers.length)}
          sub={`${enabledProviders.length} enabled`}
          subOk={enabledProviders.length > 0}
        />
        <Stat
          Glyph={Icon.List}
          label="File logging"
          value={loggingOn ? 'On' : 'Off'}
          sub={loggingOn ? 'writing logs' : 'disabled'}
          subOk={loggingOn}
        />
      </div>

      <div className="glass-panel card">
        <div className="between">
          <div className="titles">
            <div className="t1">Proxy status</div>
            <div className="t2">
              <span className="dot ok pulse" />
              <span>Backend reachable — management API responding</span>
            </div>
          </div>
          <span className="pill ok">
            <Icon.Check />
            Live
          </span>
        </div>
      </div>
    </section>
  );
}
