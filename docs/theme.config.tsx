import React from 'react'
import { useRouter } from "next/router"
import { DocsThemeConfig } from 'nextra-theme-docs'

const config: DocsThemeConfig = {
  useNextSeoProps() {
		const { asPath } = useRouter()
		if (asPath !== "/") {
			return {
				titleTemplate: "%s – Cheeto",
			}
		}
	},
  logo: (
      <>
        <img
          width="36"
          height="36"
          src="/cheeto.svg"
          alt="Cheeto"
        />
        <span style={{ marginLeft: "0.5em", fontWeight: 700, fontSize: "1.15em" }}>Cheeto</span>
      </>
  ),
  project: {
    link: 'https://github.com/pealz1/cheeto',
  },
  docsRepositoryBase: 'https://github.com/pealz1/cheeto',
  footer: {
    text: '© 2026 Cheeto',
  },
  head: (
    <>
      <link rel="shortcut icon" href="/cheeto.svg" type="image/svg+xml"/>
      <meta property="og:description" content="A secure IDL compiler written in Luau for ROBLOX buffer networking." />
    </>
  )
}

export default config
