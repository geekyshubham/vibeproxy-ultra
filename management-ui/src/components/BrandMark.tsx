/* ============================================================================
   BrandMark — the VibeRouter glyph rendered inside the accent-gradient chip
   (.brand-mark / .gate-logo). Uses the bundled glyph.png so the login screen,
   topbar, and favicon share one mark.
   ========================================================================== */
import glyphUrl from '../assets/glyph.png';

export function BrandMark({ size = 18 }: { size?: number }) {
  return (
    <img
      src={glyphUrl}
      alt="VibeRouter"
      width={size}
      height={size}
      style={{ display: 'block', objectFit: 'contain' }}
    />
  );
}

export default BrandMark;
