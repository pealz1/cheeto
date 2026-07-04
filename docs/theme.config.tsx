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
          width="40"
          height="40"
          src="https://raw.githubusercontent.com/pealz1/cheeto/main/docs/public/letter.png"
        />
      </>
  ),
  project: {
    link: 'https://github.com/pealz1/cheeto',
  },
  docsRepositoryBase: 'https://github.com/pealz1/cheeto',
  footer: {
    text: '© 2024 Cheeto',
  },
  head: (
    <>
      <link rel="shortcut icon" href="https://raw.githubusercontent.com/pealz1/cheeto/main/docs/public/letter.png" type="img/png"/>
      <meta property="og:description" content="An IDL compiler written in Luau for ROBLOX buffer networking." />
    </>
  )
}

export default config
