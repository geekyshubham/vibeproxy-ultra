/* ============================================================================
   LoadingBlock — shimmer skeleton rows (.skel) shown while a query is settling.
   ========================================================================== */
export default function LoadingBlock({ rows = 3, height = 48 }: { rows?: number; height?: number }) {
  return (
    <div className="stack" aria-busy="true" aria-live="polite">
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="skel" style={{ height }} />
      ))}
    </div>
  );
}
