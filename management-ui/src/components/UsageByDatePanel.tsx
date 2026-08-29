/* ============================================================================
   UsageByDatePanel — "what did I use on this day": totals, the provider used
   most, and the per-model breakdown for the day selected in the TopBar.

   Ranking is by cost, never by volume, because volumes arrive in unlike units
   (Kiro reports millicredits, everyone else tokens) and ordering those against
   each other would be meaningless. Cost is the one basis comparable across all
   providers. Totals arrive precomputed from the server for the same reason.
   ========================================================================== */
import { asArray } from '../lib/apiClient';
import { dayLabel, tokens, usd, volume } from '../lib/format';
import type { UsageDailyModelRow, UsageDailyProviderRow } from '../lib/types';
import { useUsageDay } from '../context/UsageDayContext';
import { useUsageDaily } from '../lib/useUsageDaily';
import Icon from '../lib/icons';
import LoadingBlock from './LoadingBlock';

const MAX_MODEL_ROWS = 12;

/** Provider accent via the --p-<id> custom properties, falling back to the app
 *  accent for any provider without a defined tint. Sanitised because the id is
 *  interpolated into a CSS var name. */
function providerTint(providerID: string): string {
  const safe = providerID.toLowerCase().replace(/[^a-z0-9-]/g, '');
  return safe ? `var(--p-${safe}, var(--accent))` : 'var(--accent)';
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="uday-stat">
      <div className="uday-stat-lbl">{label}</div>
      <div className={`uday-stat-val ${accent ? 'accent' : ''}`}>{value}</div>
    </div>
  );
}

function TopProvider({ row, costShare }: { row: UsageDailyProviderRow; costShare?: number }) {
  return (
    <div className="uday-top">
      <span className="uday-swatch" style={{ background: providerTint(row.providerID) }} />
      <div className="uday-top-info">
        <div className="uday-stat-lbl">Most used</div>
        <div className="uday-top-name">{row.providerName || row.providerID}</div>
      </div>
      <div className="uday-top-trail">
        {/* Share is cost-based and absent when the day carries no cost signal, in
            which case volume alone is the honest headline. */}
        {costShare != null && (
          <div className="uday-share">{Math.round(costShare * 100)}% of spend</div>
        )}
        <div className="uday-top-vol mono">{volume(row.totalVolume, row.volumeUnit)}</div>
      </div>
    </div>
  );
}

function ModelRow({ row }: { row: UsageDailyModelRow }) {
  return (
    <div className="uday-model">
      <span className="uday-dot" style={{ background: providerTint(row.providerID) }} />
      <span className="uday-model-name">{row.model}</span>
      <span className="grow" />
      <span className="uday-model-vol mono">{volume(row.totalVolume, row.volumeUnit)}</span>
      {row.estimatedCostUSD > 0 && (
        <span className="uday-model-cost mono">{usd(row.estimatedCostUSD)}</span>
      )}
    </div>
  );
}

export default function UsageByDatePanel() {
  const { day } = useUsageDay();
  const usage = useUsageDaily(day);

  if (usage.isLoading) {
    return (
      <div className="glass-panel card">
        <LoadingBlock rows={2} height={64} />
      </div>
    );
  }

  const data = usage.data;
  const models = asArray<UsageDailyModelRow>(data?.models);
  const providers = asArray<UsageDailyProviderRow>(data?.providers);
  const caveats = asArray<string>(data?.caveats);
  const shown = models.slice(0, MAX_MODEL_ROWS);
  const top = providers[0];

  return (
    <div className="glass-panel card">
      <div className="sec-head">
        <div className="sec-chip" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>
          <Icon.Activity />
        </div>
        <div className="sec-titles">
          <div className="sec-title">Usage on {dayLabel(day)}</div>
          <div className="sec-sub">
            {usage.isError
              ? 'Usage history unavailable'
              : models.length
                ? `${providers.length} provider${providers.length === 1 ? '' : 's'} · ${models.length} model${models.length === 1 ? '' : 's'}`
                : 'No usage recorded for this day'}
          </div>
        </div>
      </div>

      {usage.isError ? (
        <div className="small">
          Could not read the usage history. It is written by the VibeRouter app as it scans
          your CLI sessions.
        </div>
      ) : !models.length ? (
        <div className="small">
          {/* Be explicit that history starts when tracking starts — an empty older
              date is expected, not a bug. */}
          {data?.earliestDay
            ? `Recorded history starts ${dayLabel(data.earliestDay)}.`
            : 'History builds as VibeRouter scans your CLI sessions.'}
        </div>
      ) : (
        <>
          <div className="uday-stats">
            <Stat label="Tokens" value={tokens(data?.totalTokens)} />
            <Stat label="Est. API $" value={usd(data?.totalCostUSD)} accent />
            <Stat label="Requests" value={tokens(data?.totalRequests)} />
          </div>

          {top && <TopProvider row={top} costShare={top.costShare} />}

          <div className="uday-models">
            <div className="uday-stat-lbl">Models used</div>
            {shown.map((row) => (
              <ModelRow key={`${row.providerID}:${row.model}`} row={row} />
            ))}
            {models.length > shown.length && (
              <div className="uday-more">+{models.length - shown.length} more</div>
            )}
          </div>

          {/* Grok pins a whole session to its last-activity day and Copilot keeps no
              per-model split, so those days are labelled rather than presented as exact. */}
          {caveats.map((note) => (
            <div className="uday-caveat" key={note}>
              <Icon.Info />
              <span>{note}</span>
            </div>
          ))}
        </>
      )}
    </div>
  );
}
