/* ============================================================================
   AccountsTab — lists OAuth token files under ~/.cli-proxy-api. Operator can
   toggle a file disabled (PATCH /auth-files/status) or delete it
   (DELETE /auth-files?name=). The files list is normalized via pluckArray so a
   null response renders the empty state instead of crashing.
   ========================================================================== */
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { pluckArray } from '../lib/apiClient';
import type { AuthFile } from '../lib/types';
import { timeAgo } from '../lib/format';
import { providerMeta } from '../lib/providers';
import Icon from '../lib/icons';
import SectionHeader from '../components/SectionHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import ProviderLogo from '../components/ProviderLogo';
import { useToast } from '../context/ToastContext';

export default function AccountsTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const q = useManagementQuery<{ files: AuthFile[] | null }>('/auth-files');
  const [busy, setBusy] = useState<string | null>(null);

  const files = pluckArray<AuthFile>(q.data, 'files').filter((f) => f && f.name);

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['mgmt', '/auth-files'] });
    toast('Accounts refreshed', 'ok');
  }

  async function toggleDisabled(file: AuthFile) {
    setBusy(file.name);
    try {
      await apiClient.patch(`/auth-files/status?name=${encodeURIComponent(file.name)}`, {
        disabled: !file.disabled,
      });
      toast(file.disabled ? 'Account enabled' : 'Account disabled', 'ok');
      await refresh();
    } catch {
      toast('Could not update account', 'bad');
    } finally {
      setBusy(null);
    }
  }

  async function remove(file: AuthFile) {
    if (!confirm(`Delete ${file.name}? This removes the token file.`)) return;
    setBusy(file.name);
    try {
      await apiClient.del(`/auth-files?name=${encodeURIComponent(file.name)}`);
      toast('Account removed', 'ok');
      await refresh();
    } catch {
      toast('Could not remove account', 'bad');
    } finally {
      setBusy(null);
    }
  }

  return (
    <section className="view">
      <div className="glass-panel card">
        <SectionHeader
          Glyph={Icon.Users}
          title="OAuth accounts"
          sub="OAuth token files under ~/.cli-proxy-api"
          trail={
            <button className="btn btn-soft btn-sm" onClick={refresh} disabled={q.isFetching}>
              <Icon.Refresh />
              <span>Refresh</span>
            </button>
          }
        />

        {q.isLoading ? (
          <LoadingBlock rows={4} />
        ) : files.length === 0 ? (
          <EmptyState Glyph={Icon.Users} title="No accounts yet">
            Sign in to a provider from the VibeRouter menu bar. OAuth token files will appear here.
          </EmptyState>
        ) : (
          <div className="stack">
            {files.map((file) => {
              const meta = providerMeta(file.provider || file.type || file.name);
              const healthy = !file.unavailable && file.status?.toLowerCase() !== 'error';
              return (
                <div className="prov glass" key={file.name}>
                  <ProviderLogo provider={file.provider || file.type || file.name} />
                  <div className="info">
                    <div className="n">{file.label || meta.label}</div>
                    <div className="m">{file.name}</div>
                  </div>
                  <div className="row">
                    {file.disabled ? (
                      <span className="pill mut">
                        <Icon.X />
                        Disabled
                      </span>
                    ) : (
                      <span className={`pill ${healthy ? 'ok' : 'warn'}`}>
                        <span className={`dot ${healthy ? 'ok' : 'warn'}`} />
                        {healthy ? 'Active' : file.status || 'Degraded'}
                      </span>
                    )}
                    <span className="small">{timeAgo(file.updated_at || file.modtime)}</span>
                    <button
                      className={`sw ${file.disabled ? '' : 'on'}`}
                      role="switch"
                      aria-checked={!file.disabled}
                      aria-label="Toggle account"
                      disabled={busy === file.name}
                      onClick={() => toggleDisabled(file)}
                    />
                    <button
                      className="btn-icon btn-danger"
                      title="Delete account"
                      disabled={busy === file.name}
                      onClick={() => remove(file)}
                    >
                      <Icon.Trash />
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </section>
  );
}
