import Link from 'next/link'
import { CSSProperties, PointerEvent, ReactNode, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { SAMPLES, tokenize } from './code'
import styles from './landing.module.css'

const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''
const REPOSITORY = 'https://github.com/pealz1/cheeto'
const INSTALL = 'rokit add pealz1/cheeto'

/* ----------------------------------------------------------------- hooks */

function usePrefersReducedMotion() {
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

/** Fades sections in as they scroll into view. */
function useReveal(root: React.RefObject<HTMLElement>) {
  useEffect(() => {
    const element = root.current
    if (!element) return
    const targets = Array.from(element.querySelectorAll<HTMLElement>('[data-reveal]'))
    if (!('IntersectionObserver' in window)) {
      targets.forEach((target) => (target.dataset.visible = 'true'))
      return
    }
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            ;(entry.target as HTMLElement).dataset.visible = 'true'
            observer.unobserve(entry.target)
          }
        }
      },
      { rootMargin: '0px 0px -10% 0px', threshold: 0.12 }
    )
    targets.forEach((target) => observer.observe(target))
    return () => observer.disconnect()
  }, [root])
}

/** Writes the pointer position into CSS variables for spotlight effects. */
function trackPointer(event: PointerEvent<HTMLElement>) {
  const target = event.currentTarget
  const rect = target.getBoundingClientRect()
  target.style.setProperty('--mx', `${event.clientX - rect.left}px`)
  target.style.setProperty('--my', `${event.clientY - rect.top}px`)
}

/* ------------------------------------------------------------------ icons */

type IconProps = { children: ReactNode }

const Icon = ({ children }: IconProps) => (
  <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {children}
  </svg>
)

const icons = {
  bolt: (
    <Icon>
      <path d="M13 2 4 14h7l-1 8 9-12h-7l1-8z" />
    </Icon>
  ),
  type: (
    <Icon>
      <path d="M4 7V5h16v2" />
      <path d="M9 19h6" />
      <path d="M12 5v14" />
    </Icon>
  ),
  shield: (
    <Icon>
      <path d="M12 22s8-3.5 8-10V5l-8-3-8 3v7c0 6.5 8 10 8 10z" />
      <path d="m9 12 2 2 4-4" />
    </Icon>
  ),
  gauge: (
    <Icon>
      <path d="M12 14 16 9" />
      <path d="M3.34 17a10 10 0 1 1 17.32 0" />
    </Icon>
  ),
  lock: (
    <Icon>
      <rect x="4" y="11" width="16" height="10" rx="2" />
      <path d="M8 11V7a4 4 0 0 1 8 0v4" />
    </Icon>
  ),
  wrench: (
    <Icon>
      <path d="M14.7 6.3a4 4 0 0 0 5 5L22 14l-8 8-2.3-2.3a4 4 0 0 0-5-5L4 12l8-8z" />
    </Icon>
  ),
  layers: (
    <Icon>
      <path d="m12 2 10 6-10 6L2 8z" />
      <path d="m2 16 10 6 10-6" />
    </Icon>
  ),
  studio: (
    <Icon>
      <rect x="3" y="4" width="18" height="14" rx="2" />
      <path d="M8 21h8" />
      <path d="m9 9 2 2-2 2" />
      <path d="M13 13h2" />
    </Icon>
  ),
  plug: (
    <Icon>
      <path d="M9 2v6" />
      <path d="M15 2v6" />
      <path d="M6 8h12v3a6 6 0 0 1-12 0z" />
      <path d="M12 17v5" />
    </Icon>
  ),
  copy: (
    <Icon>
      <rect x="9" y="9" width="12" height="12" rx="2" />
      <path d="M5 15V5a2 2 0 0 1 2-2h10" />
    </Icon>
  ),
  check: (
    <Icon>
      <path d="m5 12 5 5L20 7" />
    </Icon>
  ),
  arrow: (
    <Icon>
      <path d="M5 12h14" />
      <path d="m13 6 6 6-6 6" />
    </Icon>
  ),
  github: (
    <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor" aria-hidden="true">
      <path d="M12 .5a11.5 11.5 0 0 0-3.64 22.41c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.37-3.88-1.37-.52-1.33-1.28-1.69-1.28-1.69-1.05-.72.08-.7.08-.7 1.16.08 1.77 1.19 1.77 1.19 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.55-.29-5.24-1.28-5.24-5.68 0-1.26.45-2.28 1.19-3.09-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.17 1.18a11 11 0 0 1 5.77 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.81 1.19 1.83 1.19 3.09 0 4.41-2.69 5.38-5.26 5.67.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.8.56A11.5 11.5 0 0 0 12 .5z" />
    </svg>
  )
}

/* --------------------------------------------------------------- content */

const FEATURES = [
  {
    icon: icons.bolt,
    title: 'Buffer-packed by default',
    body: 'Every field is written at its declared width. Integers use varints, booleans bit-pack, and events batch into a single buffer per frame.',
    wide: true
  },
  {
    icon: icons.type,
    title: 'Typed end to end',
    body: 'Luau types for the client and the server, plus optional TypeScript definitions for roblox-ts.'
  },
  {
    icon: icons.shield,
    title: 'Validated before your code runs',
    body: 'Size caps, decode budgets and payload canonicalization drop malformed data before a listener ever sees it.'
  },
  {
    icon: icons.lock,
    title: 'Policies, rate limits, honeypots',
    body: 'Declare who may send what, how often, and with which constraints. Replay protection and idempotency come built in.'
  },
  {
    icon: icons.layers,
    title: 'State channels and prediction',
    body: 'Delta-replicated channels, interpolation and prediction acknowledgements for state that changes every frame.',
    wide: true
  },
  {
    icon: icons.gauge,
    title: 'Production tooling',
    body: 'Doctor, strict mode, lockfiles, golden snapshots, load simulation, and packet capture with replay.'
  },
  {
    icon: icons.wrench,
    title: '30+ Roblox datatypes',
    body: 'CFrame, Color3, UDim2, NumberSequence, Font, EnumItem and more, each packed with purpose-built encodings.'
  },
  {
    icon: icons.studio,
    title: 'Studio plugin',
    body: 'Write, check and generate schemas without leaving Roblox Studio.'
  },
  {
    icon: icons.plug,
    title: 'Controller connections',
    body: 'Bind endpoints and state channels to friendly route names, inject one object into your controllers, and tear every subscription down with a single call.',
    wide: true
  }
]

const STEPS = [
  { title: 'Describe', body: 'Declare events, functions, types and channels in a small, readable schema.' },
  { title: 'Compile', body: 'Run cheeto. It validates the schema and emits client, server and type modules.' },
  { title: 'Require', body: 'Use the generated modules like any other ModuleScript, with full autocomplete.' }
]

const PROTECTIONS = [
  'Server-side policies run before decoding',
  'Per-event rate limits and cooldowns',
  'Replay and duplicate packet rejection',
  'Honeypot events that expose forged traffic',
  'Rotating remote names and decoy remotes',
  'Client integrity challenges and movement checks'
]

type Packet = { name: string; bytes: number; verdict: 'accepted' | 'dropped'; reason?: string }

const PACKETS: Packet[] = [
  { name: 'DealDamage', bytes: 9, verdict: 'accepted' },
  { name: 'Announce', bytes: 18, verdict: 'accepted' },
  { name: 'DealDamage', bytes: 9, verdict: 'dropped', reason: 'PolicyRejected' },
  { name: 'DealDamage', bytes: 9, verdict: 'accepted' },
  { name: 'DealDamage', bytes: 9, verdict: 'dropped', reason: 'ReplayDuplicate' },
  { name: 'GrantCurrency', bytes: 12, verdict: 'dropped', reason: 'Honeypot' },
  { name: 'Announce', bytes: 24, verdict: 'accepted' },
  { name: 'DealDamage', bytes: 4096, verdict: 'dropped', reason: 'MaxPacketBytes' },
  { name: 'DealDamage', bytes: 9, verdict: 'dropped', reason: 'RateLimit' },
  { name: 'DealDamage', bytes: 9, verdict: 'accepted' }
]

/* ------------------------------------------------------------- sections */

function InstallCommand() {
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
    <button type="button" className={styles.install} onClick={copy} aria-label="Copy install command">
      <span className={styles.prompt}>$</span>
      <code>{INSTALL}</code>
      <span className={styles.copy} data-copied={copied}>
        <span className={styles.copyIcon}>{icons.copy}</span>
        <span className={styles.checkIcon}>{icons.check}</span>
      </span>
    </button>
  )
}

function CodeWindow() {
  const [active, setActive] = useState(0)
  const [pinned, setPinned] = useState(false)
  const [indicator, setIndicator] = useState({ left: 0, width: 0 })
  const tabs = useRef<Array<HTMLButtonElement | null>>([])
  const reduced = usePrefersReducedMotion()
  const lines = useMemo(() => SAMPLES.map((sample) => tokenize(sample.source, sample.language)), [])

  useEffect(() => {
    const measure = () => {
      const tab = tabs.current[active]
      if (tab) setIndicator({ left: tab.offsetLeft, width: tab.offsetWidth })
    }
    measure()
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [active])

  useEffect(() => {
    if (pinned || reduced) return
    const timer = window.setInterval(() => setActive((index) => (index + 1) % SAMPLES.length), 5200)
    return () => window.clearInterval(timer)
  }, [pinned, reduced])

  return (
    <div className={styles.window} onPointerMove={trackPointer}>
      <div className={styles.windowBar}>
        <span className={styles.lights} aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
        <div className={styles.tabs} role="tablist" aria-label="Example files">
          {SAMPLES.map((sample, index) => (
            <button
              key={sample.file}
              ref={(element) => {
                tabs.current[index] = element
              }}
              type="button"
              role="tab"
              aria-selected={active === index}
              className={styles.tab}
              data-active={active === index}
              onClick={() => {
                setActive(index)
                setPinned(true)
              }}
            >
              {sample.file}
            </button>
          ))}
          <span
            className={styles.tabIndicator}
            style={{ transform: `translateX(${indicator.left}px)`, width: indicator.width }}
            aria-hidden="true"
          />
        </div>
      </div>
      <div className={styles.codeStack}>
        {SAMPLES.map((sample, index) => (
          <pre key={sample.file} className={styles.code} data-active={active === index} aria-hidden={active !== index}>
            {lines[index].map((line, row) => (
              <span key={row} className={styles.line} style={{ '--row': row } as CSSProperties}>
                <span className={styles.gutter}>{row + 1}</span>
                {line.map((token, column) => (
                  <span key={column} className={token.kind ? styles[token.kind] : undefined}>
                    {token.text}
                  </span>
                ))}
                {'\n'}
              </span>
            ))}
          </pre>
        ))}
      </div>
    </div>
  )
}

function PacketInspector() {
  const reduced = usePrefersReducedMotion()
  const [cursor, setCursor] = useState(5)

  useEffect(() => {
    if (reduced) return
    const timer = window.setInterval(() => setCursor((value) => value + 1), 1500)
    return () => window.clearInterval(timer)
  }, [reduced])

  const rows = Array.from({ length: 5 }, (_, offset) => {
    const index = cursor - offset
    return { key: index, packet: PACKETS[((index % PACKETS.length) + PACKETS.length) % PACKETS.length] }
  })

  return (
    <div className={styles.inspector} onPointerMove={trackPointer}>
      <div className={styles.inspectorHeader}>
        <span className={styles.liveDot} aria-hidden="true" />
        <span>Server · incoming</span>
        <span className={styles.inspectorMeta}>Security.OnViolation</span>
      </div>
      <ul className={styles.packets}>
        {rows.map(({ key, packet }) => (
          <li key={key} className={styles.packet} data-verdict={packet.verdict}>
            <span className={styles.packetName}>{packet.name}</span>
            <span className={styles.packetBytes}>{packet.bytes} B</span>
            <span className={styles.packetVerdict}>{packet.verdict === 'accepted' ? 'Accepted' : packet.reason}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}

/* ---------------------------------------------------------------- page */

export default function Landing() {
  const root = useRef<HTMLDivElement>(null)
  const hero = useRef<HTMLElement>(null)
  useReveal(root)

  useEffect(() => {
    const element = hero.current
    if (!element || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    let frame = 0
    const onMove = (event: globalThis.PointerEvent) => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => {
        const x = event.clientX / window.innerWidth - 0.5
        const y = event.clientY / window.innerHeight - 0.5
        element.style.setProperty('--px', x.toFixed(3))
        element.style.setProperty('--py', y.toFixed(3))
      })
    }
    window.addEventListener('pointermove', onMove, { passive: true })
    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('pointermove', onMove)
    }
  }, [])

  return (
    <div className={styles.page} ref={root}>
      <section className={styles.hero} ref={hero}>
        <div className={styles.aurora} aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <div className={styles.gridLines} aria-hidden="true" />

        <div className={styles.heroInner}>
          <a className={styles.eyebrow} href={`${REPOSITORY}/releases/latest`} target="_blank" rel="noreferrer" data-reveal>
            <span className={styles.eyebrowDot} />
            Version 1.0 is out
            <span className={styles.eyebrowArrow}>{icons.arrow}</span>
          </a>

          <div className={styles.heroLogoWrap} data-reveal>
            <img className={styles.heroLogo} src={`${basePath}/cheeto.svg`} width={88} height={88} alt="" />
          </div>

          <h1 className={styles.title} data-reveal style={{ '--delay': '60ms' } as CSSProperties}>
            Roblox networking,
            <br />
            <span className={styles.gradientText}>compiled.</span>
          </h1>

          <p className={styles.lede} data-reveal style={{ '--delay': '120ms' } as CSSProperties}>
            Describe your events once. Cheeto generates buffer-packed, fully typed Luau for the client and the server,
            with validation, rate limits and anti-exploit protection built in.
          </p>

          <div className={styles.actions} data-reveal style={{ '--delay': '180ms' } as CSSProperties}>
            <Link href="/getting-started/installation" className={styles.primary}>
              Get started
              <span className={styles.buttonArrow}>{icons.arrow}</span>
            </Link>
            <a href={REPOSITORY} className={styles.secondary} target="_blank" rel="noreferrer">
              {icons.github}
              Star on GitHub
            </a>
          </div>

          <div data-reveal style={{ '--delay': '240ms' } as CSSProperties}>
            <InstallCommand />
          </div>
        </div>

        <div className={styles.showcase} data-reveal style={{ '--delay': '320ms' } as CSSProperties}>
          <CodeWindow />
        </div>
      </section>

      <section className={styles.strip} data-reveal>
        {['30+ Roblox datatypes', 'Luau and TypeScript output', 'Protocol v2 handshake', 'Self-contained modules'].map((item) => (
          <span key={item} className={styles.pill}>
            {item}
          </span>
        ))}
      </section>

      <section className={styles.section}>
        <header className={styles.sectionHeader} data-reveal>
          <span className={styles.kicker}>Features</span>
          <h2>Everything the network layer should have done already.</h2>
          <p>One schema gives you the fast path, the typed API and the guard rails, generated together so they never drift apart.</p>
        </header>

        <div className={styles.bento}>
          {FEATURES.map((feature, index) => (
            <article
              key={feature.title}
              className={styles.card}
              data-wide={feature.wide ? 'true' : undefined}
              data-reveal
              style={{ '--delay': `${(index % 3) * 70}ms` } as CSSProperties}
              onPointerMove={trackPointer}
            >
              <span className={styles.cardIcon}>{feature.icon}</span>
              <h3>{feature.title}</h3>
              <p>{feature.body}</p>
            </article>
          ))}
        </div>
      </section>

      <section className={styles.section}>
        <header className={styles.sectionHeader} data-reveal>
          <span className={styles.kicker}>How it works</span>
          <h2>From schema to shipped in three steps.</h2>
        </header>

        <ol className={styles.steps}>
          {STEPS.map((step, index) => (
            <li key={step.title} className={styles.step} data-reveal style={{ '--delay': `${index * 90}ms` } as CSSProperties}>
              <span className={styles.stepNumber}>{index + 1}</span>
              <h3>{step.title}</h3>
              <p>{step.body}</p>
            </li>
          ))}
        </ol>
      </section>

      <section className={`${styles.section} ${styles.split}`}>
        <div data-reveal>
          <span className={styles.kicker}>Security</span>
          <h2>Built for games people try to break.</h2>
          <p className={styles.splitLede}>
            Clients can always see the traffic they receive. Cheeto makes that traffic hard to abuse: authority stays on
            the server, and anything that does not match the schema is dropped with a typed reason you can act on.
          </p>
          <ul className={styles.checks}>
            {PROTECTIONS.map((item) => (
              <li key={item}>
                <span className={styles.checkBadge}>{icons.check}</span>
                {item}
              </li>
            ))}
          </ul>
          <Link href="/guides/maximum-security" className={styles.textLink}>
            Read the security guide
            <span className={styles.buttonArrow}>{icons.arrow}</span>
          </Link>
        </div>
        <div data-reveal style={{ '--delay': '120ms' } as CSSProperties}>
          <PacketInspector />
        </div>
      </section>

      <section className={styles.section}>
        <div className={styles.cta} data-reveal onPointerMove={trackPointer}>
          <h2>Start building with Cheeto.</h2>
          <p>Install the compiler, write a schema, and have typed networking running in a few minutes.</p>
          <div className={styles.actions}>
            <Link href="/getting-started/quick-start" className={styles.primary}>
              Read the quick start
              <span className={styles.buttonArrow}>{icons.arrow}</span>
            </Link>
            <Link href="/language/options" className={styles.secondary}>
              Language reference
            </Link>
          </div>
        </div>
      </section>
    </div>
  )
}
