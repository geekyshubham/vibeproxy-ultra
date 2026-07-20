/* ============================================================================
   SectionHeader — the chip + title + subtitle + trailing-actions row that opens
   every panel section (.sec-head / .sec-chip / .sec-titles / .sec-trail).
   ========================================================================== */
import type { ComponentType, ReactNode, SVGProps } from 'react';

interface Props {
  Glyph: ComponentType<SVGProps<SVGSVGElement>>;
  title: string;
  sub?: string;
  tint?: string;
  trail?: ReactNode;
}

export default function SectionHeader({ Glyph, title, sub, tint, trail }: Props) {
  return (
    <div className="sec-head">
      <div
        className="sec-chip"
        style={{
          background: tint ? `color-mix(in srgb, ${tint} 18%, transparent)` : 'var(--accent-soft)',
          color: tint ?? 'var(--accent)',
        }}
      >
        <Glyph />
      </div>
      <div className="sec-titles">
        <div className="sec-title">{title}</div>
        {sub && <div className="sec-sub">{sub}</div>}
      </div>
      {trail && <div className="sec-trail">{trail}</div>}
    </div>
  );
}
