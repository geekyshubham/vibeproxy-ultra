/* ============================================================================
   ProviderLogo — brand badge for a provider (.plogo). Uses the SAME icon-*.png
   assets the Swift menu bar app ships, so icons are consistent across the
   management console and the native app. Providers without a shipped icon fall
   back to tinted initials.
   ========================================================================== */
import { providerMeta } from '../lib/providers';

// The brand PNGs shared with the Swift app (src/Sources/Resources/icon-*.png).
import iconAntigravity from '../assets/providers/icon-antigravity.png';
import iconClaude from '../assets/providers/icon-claude.png';
import iconCodex from '../assets/providers/icon-codex.png';
import iconCopilot from '../assets/providers/icon-copilot.png';
import iconGemini from '../assets/providers/icon-gemini.png';
import iconGrok from '../assets/providers/icon-grok.png';
import iconKiro from '../assets/providers/icon-kiro.png';
import iconQwen from '../assets/providers/icon-qwen.png';
import iconZai from '../assets/providers/icon-zai.png';

// Provider key → brand icon. Keys match providers.ts. Missing → initials.
const ICONS: Record<string, string> = {
  antigravity: iconAntigravity,
  claude: iconClaude,
  codex: iconCodex,
  copilot: iconCopilot,
  gemini: iconGemini,
  vertex: iconGemini, // Vertex serves Gemini models — reuse the Gemini mark.
  grok: iconGrok,
  kiro: iconKiro,
  qwen: iconQwen,
  zai: iconZai,
  'opencode-go': iconCodex,
};

export default function ProviderLogo({ provider, size = 30 }: { provider: string; size?: number }) {
  const meta = providerMeta(provider);
  const tint = `var(${meta.tintVar})`;
  const iconSrc = ICONS[meta.key];

  if (iconSrc) {
    return (
      <div
        className="plogo"
        style={{
          width: size,
          height: size,
          background: `color-mix(in srgb, ${tint} 18%, transparent)`,
        }}
        title={meta.label}
      >
        <img
          src={iconSrc}
          alt={meta.label}
          width={Math.round(size * 0.62)}
          height={Math.round(size * 0.62)}
          style={{ objectFit: 'contain', display: 'block' }}
        />
      </div>
    );
  }

  // Fallback: tinted initials for providers without a shipped icon.
  return (
    <div
      className="plogo"
      style={{
        width: size,
        height: size,
        background: `color-mix(in srgb, ${tint} 22%, transparent)`,
        color: tint,
      }}
      title={meta.label}
    >
      {meta.short}
    </div>
  );
}
