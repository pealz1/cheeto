import type { ReactNode } from 'react'

type Side = 'server' | 'client' | 'both' | 'schema' | 'cli'

const SIDE_LABEL: Record<Side, string> = {
  server: 'Server',
  client: 'Client',
  both: 'Server + Client',
  schema: 'Schema',
  cli: 'CLI'
}

type SigProps = {
  side?: Side
  yields?: boolean
  deprecated?: boolean
  children: ReactNode
}

/** A member signature strip: where it runs, whether it yields, then the call shape. */
export function Sig({ side = 'both', yields, deprecated, children }: SigProps) {
  return (
    <div className="ref-sig">
      <div className="ref-sig-meta">
        <span className="ref-badge" data-side={side}>
          {SIDE_LABEL[side]}
        </span>
        {yields && <span className="ref-badge">Yields</span>}
        {deprecated && (
          <span className="ref-badge" data-tone="warn">
            Deprecated
          </span>
        )}
      </div>
      <code className="ref-sig-code">{children}</code>
    </div>
  )
}

type SpecProps = {
  type?: ReactNode
  default?: ReactNode
  values?: ReactNode
  on?: ReactNode
  since?: ReactNode
}

/** Compact facts for an option or a declaration field. */
export function Spec({ type, default: fallback, values, on }: SpecProps) {
  const rows: Array<[string, ReactNode]> = []
  if (type !== undefined) rows.push(['Type', type])
  if (fallback !== undefined) rows.push(['Default', fallback])
  if (values !== undefined) rows.push(['Values', values])
  if (on !== undefined) rows.push(['Applies to', on])
  return (
    <dl className="ref-spec">
      {rows.map(([term, value]) => (
        <div key={term}>
          <dt>{term}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  )
}
