/* ============================================================================
   EmptyState — centered bubble + title + copy for empty collections (.empty).
   This is what renders instead of a crash when a list comes back null/[].
   ========================================================================== */
import type { ComponentType, ReactNode, SVGProps } from 'react';

interface Props {
  Glyph: ComponentType<SVGProps<SVGSVGElement>>;
  title: string;
  children?: ReactNode;
  action?: ReactNode;
}

export default function EmptyState({ Glyph, title, children, action }: Props) {
  return (
    <div className="empty">
      <div className="bubble">
        <Glyph />
      </div>
      <h3>{title}</h3>
      {children && <p>{children}</p>}
      {action}
    </div>
  );
}
