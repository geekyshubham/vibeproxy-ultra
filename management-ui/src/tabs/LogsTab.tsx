/* ============================================================================
   LogsTab — recent request log lines. The backend returns
   {"error":"logging to file disabled"} when file logging is off, and a logs
   array otherwise. We detect the error envelope (errorMessageOf) and render a
   notice + a toggle to enable logging, instead of calling .map on a non-array.
   ========================================================================== */
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { asArray, errorMessageOf } from '../lib/apiClient';
import type { BackendConfig, LogLine } from '../lib/types';
import { timeAgo } from '../lib/format';
import Icon from '../lib/icons';
import SectionHeader from '../components/SectionHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import { useToast } from '../context/ToastContext';

function normalizeLogs(data: unknown): LogLine[] {
  // Backend (GetLogs) returns {lines: string[], line-count, latest-timestamp}
  // when logging is on. Also tolerate a bare array or {logs:[...]}.
  const raw: unknown =
    Array.isArray(data)
      ? data
      : data && typeof data === 'object'
        ? ((data as Record<string, unknown>).lines ?? (data as Record<string, unknown>).logs)
        : undefined;

  const arr = asArray<unknown>(raw);
  return arr.map((item): LogLine => {
    if (typeof item === 'string') return { message: item };
    if (item && typeof item === 'object') return item as LogLine;
    return { message: String(item) };
  });
}

export default function LogsTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const cfg = useManagementQuery<BackendConfig>('/config');
  const loggingOn = Boolean(cfg.data?.['logging-to-file']);

  const logsQ = useManagementQuery<unknown>('/logs', {
    enabled: loggingOn,
    refetchInterval: loggingOn ? 5000 : undefined,
  });

  const disabledMsg = errorMessageOf(logsQ.data);
  const lines = normalizeLogs(logsQ.data);

  async function toggleLogging(next: boolean) {
    try {
      // Bool setter takes {"value": <bool>}, route is PATCH.
      await apiClient.patch('/logging-to-file', { value: next });
      await qc.invalidateQueries({ queryKey: ['mgmt', '/config'] });
      await qc.invalidateQueries({ queryKey: ['mgmt', '/logs'] });
      toast(next ? 'File logging enabled' : 'File logging disabled', 'ok');
    } catch {
      toast('Could not change logging', 'bad');
    }
  }

  return (
    <section className="view">
      <div className="glass-panel card">
        <SectionHeader
          Glyph={Icon.List}
          title="Request logs"
          sub="Recent calls proxied through VibeRouter"
          trail={
            <div className="row">
              <span className="small">File logging</span>
              <button
                className={`sw ${loggingOn ? 'on' : ''}`}
                role="switch"
                aria-checked={loggingOn}
                aria-label="Toggle file logging"
                onClick={() => toggleLogging(!loggingOn)}
              />
            </div>
          }
        />

        {cfg.isLoading ? (
          <LoadingBlock rows={4} />
        ) : !loggingOn || disabledMsg ? (
          <EmptyState
            Glyph={Icon.List}
            title="File logging is off"
            action={
              <button className="btn btn-primary" onClick={() => toggleLogging(true)}>
                <Icon.Power />
                <span>Enable logging</span>
              </button>
            }
          >
            {disabledMsg ?? 'Turn on file logging to capture request lines here.'}
          </EmptyState>
        ) : logsQ.isLoading ? (
          <LoadingBlock rows={4} />
        ) : lines.length === 0 ? (
          <EmptyState Glyph={Icon.List} title="No log lines yet">
            Logging is on, but nothing has been recorded yet. Make a request through the proxy.
          </EmptyState>
        ) : (
          <table className="tbl">
            <thead>
              <tr>
                <th>Time</th>
                <th>Level</th>
                <th>Model</th>
                <th>Status</th>
                <th>Message</th>
              </tr>
            </thead>
            <tbody>
              {lines.slice(0, 200).map((l, i) => (
                <tr key={i}>
                  <td className="mono">{timeAgo(l.time || l.timestamp)}</td>
                  <td>{l.level ?? '—'}</td>
                  <td className="mono">{l.model ?? '—'}</td>
                  <td>{l.status ?? '—'}</td>
                  <td>{l.message ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}
