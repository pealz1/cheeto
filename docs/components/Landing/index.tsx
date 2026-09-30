import Link from 'next/link'
import { CSSProperties, useCallback, useEffect, useMemo, useState } from 'react'
import { SAMPLES, tokenize } from './code'
import styles from './landing.module.css'

const REPOSITORY = 'https://github.com/pealz1/cheeto'
const INSTALL = 'rokit add pealz1/cheeto'

const SPECS: Array<[string, string]> = [
  ['Input', 'One .cheeto schema'],
  ['Output', 'Client + server Luau, optional roblox-ts types'],
  ['Wire format', 'Batched binary frames, one remote each way'],
  ['Integers', 'LEB128 varints, declared ranges'],
  ['Datatypes', '30+ Roblox types'],
  ['Runtime deps', 'None, modules are self-contained'],
  ['License', 'MIT']
]

type Cell = { key: string; hex: string; label: string; detail: string; accent?: boolean }

// Frame written by the v2 encoder for DealDamage.Fire({ Target = target, Damage = 25 })
const FRAME: Cell[] = [
  { key: 'idx', hex: 'id', label: 'Event index', detail: 'u8, assigned per event at compile time' },
  { key: 'flags', hex: '00', label: 'Flags', detail: 'u8, bit 0 set only when a prediction id follows' },
  { key: 'len', hex: '01', label: 'Payload length', detail: 'varint, bytes of payload in this frame' },
  { key: 'inst', hex: '01', label: 'Instance count', detail: 'varint, Target rides in the instance array' },
  { key: 'damage', hex: '19', label: 'Damage = 25', detail: 'u16 as a varint, one byte instead of two', accent: true }
]

type Packet = { name: string; bytes: number; reason?: string }

const PACKETS: Packet[] = [
  { name: 'DealDamage', bytes: 5 },
  { name: 'Announce', bytes: 18 },
  { name: 'DealDamage', bytes: 5, reason: 'PolicyRejected' },
  { name: 'DealDamage', bytes: 5 },
  { name: 'DealDamage', bytes: 5, reason: 'ReplayDuplicate' },
  { name: 'GrantCurrency', bytes: 12, reason: 'Honeypot' },
  { name: 'Announce', bytes: 24 },
  { name: 'DealDamage', bytes: 4096, reason: 'MaxPacketBytes' },
  { name: 'DealDamage', bytes: 5, reason: 'RateLimit' },
  { name: 'DealDamage', bytes: 5 }
]

const FEATURES: Array<[string, string]> = [
  ['Buffer-packed by default', 'Fields are written at their declared width, integers as varints, booleans bit-packed, and every event in a frame shares one buffer.'],
  ['Typed end to end', 'Generated Luau types on both sides, plus TypeScript definitions for roblox-ts projects.'],
  ['Validated before your code runs', 'Size caps, decode budgets and canonicalization drop malformed payloads before a listener sees them.'],
  ['Policies and rate limits', 'Declare who may send what and how often. Your rules run before the payload is even decoded.'],
  ['State channels', 'Server-owned state sent as snapshots and delta patches, per player, group, zone or everyone.'],
  ['Production tooling', 'Doctor and strict checks, a lockfile for schema review, metrics, and packet capture with replay.'],
  ['Studio plugin', 'Write, check and generate schemas without leaving Roblox Studio.'],
  ['Controller connections', 'Bind endpoints to route names, inject one object into controllers, and tear it all down with one call.']
]

const STEPS: Array<[string, string, string, string]> = [
  ['Describe', 'Declare events, functions, types and channels in a small schema.', '/reference/declarations/event', 'Schema reference'],
  ['Compile', 'Run cheeto. It checks the schema and writes the client, server and type modules.', '/reference/cli', 'CLI reference'],
  ['Require', 'Use the generated modules like any ModuleScript, with full autocomplete.', '/getting-started/quick-start', 'Quick start']
]

function useReducedMotion() {
  const [reduced, setReduced] = useState(false)
  useEffect(() => {
    const query = window.matchMedia('(prefers-reduced-motion: reduce)')
    const update = () => setReduced(query.matches)
    update()
    query.addEventListener('change', update)
    return () => query.removeEventListener('change', update)
  }, [])
  return reduced
}

function Install() {
  const [copied, setCopied] = useState(false)
  const copy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(INSTALL)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1600)
    } catch {
      setCopied(false)
    }
  }, [])
  return (
    <button type="button" className={styles.install} onClick={copy} aria-label={`Copy ${INSTALL}`}>
      <span className={styles.prompt} aria-hidden="true">$</span>
      <code>{INSTALL}</code>
      <span className={styles.copyState} aria-live="polite">{copied ? 'Copied' : 'Copy'}</span>
    </button>
  )
}

function Code({ index }: { index: number }) {
  const sample = SAMPLES[index]
  const lines = useMemo(() => tokenize(sample.source, sample.language), [sample])
  return (
    <pre className={styles.code}>
      {lines.map((line, row) => (
        <span key={row} className={styles.line}>
          <span className={styles.gutter} aria-hidden="true">{String(row + 1).padStart(2, '0')}</span>
          {line.map((token, column) => (
            <span key={column} className={token.kind ? styles[token.kind] : undefined}>{token.text}</span>
          ))}
          {'\n'}
        </span>
      ))}
    </pre>
  )
}

function Compiler() {
  const [side, setSide] = useState(1)
  return (
    <div className={styles.compiler}>
      <div className={styles.pane}>
        <div className={styles.paneBar}>
          <span>IN</span>
          <span>{SAMPLES[0].file}</span>
        </div>
        <Code index={0} />
      </div>
      <div className={styles.pipe} aria-hidden="true">
        <span className={styles.pipeLabel}>cheeto network.cheeto</span>
        <span className={styles.pipeArrow} />
      </div>
      <div className={styles.pane}>
        <div className={styles.paneBar} role="tablist" aria-label="Generated output">
          <span>OUT</span>
          {[1, 2].map((index) => (
            <button
              key={index}
              type="button"
              role="tab"
              aria-selected={side === index}
              className={styles.paneTab}
              onClick={() => setSide(index)}
            >
              {SAMPLES[index].file}
            </button>
          ))}
        </div>
        <Code index={side} />
      </div>
    </div>
  )
}

function FrameDiagram() {
  const [focus, setFocus] = useState<string | null>(null)
  return (
    <div className={styles.frame}>
      <div className={styles.bytesRow}>
        <div className={styles.bytes} role="list" aria-label="Frame bytes">
          {FRAME.map((cell, offset) => (
            <span
              key={cell.key}
              role="listitem"
              tabIndex={0}
              className={styles.byte}
              data-accent={cell.accent}
              data-focus={focus === cell.key}
              onMouseEnter={() => setFocus(cell.key)}
              onMouseLeave={() => setFocus(null)}
              onFocus={() => setFocus(cell.key)}
              onBlur={() => setFocus(null)}
              aria-label={`${cell.label}: ${cell.hex}`}
            >
              <span className={styles.offset}>{String(offset).padStart(2, '0')}</span>
              <span className={styles.hex}>{cell.hex}</span>
            </span>
          ))}
        </div>
        <div className={styles.side}>
          <span className={styles.offset}>INSTANCES</span>
          <span className={styles.sideCell}>[1] Target: Player</span>
        </div>
      </div>
      <dl className={styles.legend}>
        {FRAME.map((cell) => (
          <div key={cell.key} className={styles.legendRow} data-focus={focus === cell.key} data-accent={cell.accent}>
            <dt>{cell.label}</dt>
            <dd>{cell.detail}</dd>
          </div>
        ))}
      </dl>
      <p className={styles.note}>
        Five bytes on the wire. With <code>Damage = 300</code> the varint grows to two bytes, <code>AC 02</code>, still
        within the declared <code>u16(0..500)</code>.
      </p>
    </div>
  )
}

function IngressLog() {
  const reduced = useReducedMotion()
  const [cursor, setCursor] = useState(PACKETS.length - 1)
  useEffect(() => {
    if (reduced) return
    const timer = window.setInterval(() => setCursor((value) => value + 1), 1400)
    return () => window.clearInterval(timer)
  }, [reduced])
  const rows = Array.from({ length: 6 }, (_, offset) => {
    const seq = cursor - offset
    return { seq, packet: PACKETS[((seq % PACKETS.length) + PACKETS.length) % PACKETS.length] }
  })
  return (
    <table className={styles.log}>
      <caption>Server ingress, as reported to Security.OnViolation</caption>
      <thead>
        <tr>
          <th scope="col">Seq</th>
          <th scope="col">Event</th>
          <th scope="col">Bytes</th>
          <th scope="col">Verdict</th>
        </tr>
      </thead>
      <tbody>
        {rows.map(({ seq, packet }) => (
          <tr key={seq} data-dropped={Boolean(packet.reason)}>
            <td>{String(seq + 1000).slice(-4)}</td>
            <td>{packet.name}</td>
            <td>{packet.bytes}</td>
            <td>{packet.reason ?? 'Accepted'}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function Section({ id, number, title, children }: { id: string; number: string; title: string; children: React.ReactNode }) {
  return (
    <section className={styles.section} aria-labelledby={id}>
      <header className={styles.sectionHead}>
        <span className={styles.sectionNumber}>{number}</span>
        <h2 id={id}>{title}</h2>
      </header>
      {children}
    </section>
  )
}

export default function Landing() {
  return (
    <div className={styles.page}>
      <div className={styles.titleBlock} aria-hidden="true">
        <span>Cheeto</span>
        <span>Networking compiler for Roblox</span>
        <span>Doc CH-001</span>
        <span>Rev 1.0.0</span>
      </div>

      <section className={styles.hero}>
        <div className={styles.heroCopy}>
          <p className={styles.kicker}>§0 Overview</p>
          <h1 className={styles.title}>
            Roblox networking, <em>compiled</em> from one schema.
          </h1>
          <p className={styles.lede}>
            Describe your events once. Cheeto writes buffer-packed, fully typed Luau for the client and the server, with
            validation, rate limits and anti-exploit checks generated alongside.
          </p>
          <div className={styles.actions}>
            <Link href="/getting-started/installation" className={styles.primary}>
              Read the docs
            </Link>
            <a href={REPOSITORY} className={styles.secondary} target="_blank" rel="noreferrer">
              Source on GitHub
            </a>
          </div>
          <Install />
        </div>
        <aside className={styles.specs} aria-label="Key specifications">
          <p className={styles.specsTitle}>Table 0. Key specifications</p>
          <dl>
            {SPECS.map(([term, value]) => (
              <div key={term} className={styles.specRow}>
                <dt>{term}</dt>
                <dd>{value}</dd>
              </div>
            ))}
          </dl>
        </aside>
      </section>

      <Section id="fig-compile" number="Fig. 1" title="One schema in, two typed modules out">
        <Compiler />
      </Section>

      <Section id="fig-frame" number="Fig. 2" title="Anatomy of a DealDamage frame">
        <FrameDiagram />
      </Section>

      <Section id="security" number="§3" title="Bad packets never reach your handlers">
        <div className={styles.securityGrid}>
          <div className={styles.securityCopy}>
            <p>
              Policies run on the server before a payload is decoded. Everything that fails a check is dropped, counted
              and reported with a reason you can act on.
            </p>
            <ol className={styles.checks}>
              <li>Policies before decoding</li>
              <li>Per-event rate limits and cooldowns</li>
              <li>Replay and duplicate rejection</li>
              <li>Honeypot events for forged traffic</li>
              <li>Rotating remote names and decoys</li>
              <li>Client integrity and movement checks</li>
            </ol>
            <Link href="/security/overview" className={styles.textLink}>
              Security model
            </Link>
          </div>
          <IngressLog />
        </div>
      </Section>

      <Section id="features" number="§4" title="What the schema buys you">
        <ol className={styles.features}>
          {FEATURES.map(([title, body], index) => (
            <li key={title} style={{ '--i': index } as CSSProperties}>
              <span className={styles.featureNumber}>4.{index + 1}</span>
              <h3>{title}</h3>
              <p>{body}</p>
            </li>
          ))}
        </ol>
      </Section>

      <Section id="start" number="§5" title="Start in three steps">
        <ol className={styles.steps}>
          {STEPS.map(([title, body, href, linkLabel], index) => (
            <li key={title}>
              <span className={styles.stepNumber}>{index + 1}</span>
              <h3>{title}</h3>
              <p>{body}</p>
              <Link href={href} className={styles.textLink}>
                {linkLabel}
              </Link>
            </li>
          ))}
        </ol>
      </Section>
    </div>
  )
}
