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
    <img src={`${basePath}/cheeto.svg`} width={30} height={30} alt="" />
    <span>Cheeto</span>
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
      <meta name="theme-color" media="(prefers-color-scheme: light)" content="#fbf8f4" />
      <meta name="theme-color" media="(prefers-color-scheme: dark)" content="#0b0a09" />
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
  banner: {
    key: 'cheeto-1.0.0',
    text: (
      <a href={`${repository}/releases/tag/v1.0.0`} target="_blank" rel="noreferrer">
        Cheeto 1.0 is here. Read the release notes →
      </a>
    )
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
    content: 'Question? Give us feedback →',
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
