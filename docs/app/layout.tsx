import type { Metadata, Viewport } from 'next'
import type { ReactNode } from 'react'
import { Archivo, IBM_Plex_Mono } from 'next/font/google'
import { Head, Search } from 'nextra/components'
import { getPageMap } from 'nextra/page-map'
import { Footer, Layout, Navbar } from 'nextra-theme-docs'
import 'nextra-theme-docs/style.css'
import '../styles/globals.css'

const sans = Archivo({ subsets: ['latin'], axes: ['wdth'], variable: '--font-sans', display: 'swap' })
const mono = IBM_Plex_Mono({ subsets: ['latin'], weight: ['400', '500', '600'], variable: '--font-mono', display: 'swap' })

const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''
// Absolute site URL for social previews, set by the deploy workflow
const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? basePath
const repository = 'https://github.com/pealz1/cheeto'
const description =
  'Cheeto compiles a small schema language into fast, fully typed and hardened Luau networking code for Roblox.'

export const metadata: Metadata = {
  title: { default: 'Cheeto: typed, secure networking for Roblox', template: '%s – Cheeto' },
  description,
  icons: { icon: { url: `${basePath}/cheeto.svg`, type: 'image/svg+xml' } },
  openGraph: { type: 'website', images: `${siteUrl}/og.png` },
  twitter: { card: 'summary_large_image' }
}

export const viewport: Viewport = {
  viewportFit: 'cover',
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#f3efe6' },
    { media: '(prefers-color-scheme: dark)', color: '#13120f' }
  ]
}

const logo = (
  <span className="cheeto-logo">
    <img src={`${basePath}/cheeto.svg`} width={26} height={26} alt="" />
    <span>Cheeto</span>
    <small>1.0</small>
  </span>
)

const footer = (
  <Footer>
    <div className="cheeto-footer">
      <span>MIT licensed · © {new Date().getFullYear()} pealz1 and contributors</span>
      <span className="cheeto-footer-links">
        <a href={repository} target="_blank" rel="noreferrer">GitHub</a>
        <a href={`${repository}/releases`} target="_blank" rel="noreferrer">Releases</a>
        <a href={`${repository}/blob/main/CONTRIBUTING.md`} target="_blank" rel="noreferrer">Contributing</a>
      </span>
    </div>
  </Footer>
)

export default async function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" dir="ltr" suppressHydrationWarning className={`${sans.variable} ${mono.variable}`}>
      <Head color={{ hue: 24, saturation: 95 }} />
      <body>
        <Layout
          navbar={<Navbar logo={logo} projectLink={repository} />}
          footer={footer}
          search={<Search placeholder="Search the docs…" />}
          pageMap={await getPageMap()}
          docsRepositoryBase={`${repository}/tree/main/docs`}
          editLink="Edit this page on GitHub →"
          feedback={{ content: 'Open an issue about this page →', labels: 'documentation' }}
          sidebar={{ defaultMenuCollapseLevel: 2, toggleButton: true }}
          toc={{ backToTop: true }}
          nextThemes={{ defaultTheme: 'system' }}
          copyPageButton={false}
        >
          {children}
        </Layout>
      </body>
    </html>
  )
}
