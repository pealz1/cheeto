import React from 'react'
import { useRouter } from 'next/router'
import { DocsThemeConfig, useConfig } from 'nextra-theme-docs'

const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''
// Absolute site URL for social previews, set by the deploy workflow
const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? basePath
const repository = 'https://github.com/pealz1/cheeto'
const description =
  'Cheeto compiles a small schema language into fast, fully typed and hardened Luau networking code for Roblox.'

const Logo = () => (
  <span className="cheeto-logo">
    <img src={`${basePath}/cheeto.svg`} width={26} height={26} alt="" />
    <span>Cheeto</span>
    <small>1.0</small>
  </span>
)

const Head = () => {
  const { asPath } = useRouter()
  const { frontMatter, title } = useConfig()
  const pageTitle = asPath === '/' ? 'Cheeto: typed, secure networking for Roblox' : `${title} – Cheeto`
  const pageDescription = frontMatter.description || description

  return (
    <>
      <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
      <meta name="description" content={pageDescription} />
      <meta property="og:title" content={pageTitle} />
      <meta property="og:description" content={pageDescription} />
      <meta property="og:type" content="website" />
      <meta property="og:image" content={`${siteUrl}/og.png`} />
      <meta name="twitter:card" content="summary_large_image" />
      <meta name="theme-color" media="(prefers-color-scheme: light)" content="#f3efe6" />
      <meta name="theme-color" media="(prefers-color-scheme: dark)" content="#13120f" />
      <link rel="icon" href={`${basePath}/cheeto.svg`} type="image/svg+xml" />
    </>
  )
}

const config: DocsThemeConfig = {
  logo: <Logo />,
  project: { link: repository },
  docsRepositoryBase: `${repository}/tree/main/docs`,
  primaryHue: 24,
  primarySaturation: 95,
  darkMode: true,
  nextThemes: { defaultTheme: 'system' },
  head: Head,
  useNextSeoProps() {
    const { asPath } = useRouter()
    if (asPath !== '/') {
      return { titleTemplate: '%s – Cheeto' }
    }
    return { title: 'Cheeto: typed, secure networking for Roblox' }
  },
  sidebar: {
    defaultMenuCollapseLevel: 1,
    toggleButton: true
  },
  toc: {
    backToTop: true
  },
  editLink: {
    text: 'Edit this page on GitHub →'
  },
  feedback: {
    content: 'Open an issue about this page →',
    labels: 'documentation'
  },
  search: {
    placeholder: 'Search the docs…'
  },
  footer: {
    text: (
      <div className="cheeto-footer">
        <span>
          MIT licensed · © {new Date().getFullYear()} pealz1 and contributors
        </span>
        <span className="cheeto-footer-links">
          <a href={repository} target="_blank" rel="noreferrer">GitHub</a>
          <a href={`${repository}/releases`} target="_blank" rel="noreferrer">Releases</a>
          <a href={`${repository}/blob/main/CONTRIBUTING.md`} target="_blank" rel="noreferrer">Contributing</a>
        </span>
      </div>
    )
  }
}

export default config
