import { readFileSync } from 'fs'
import nextra from 'nextra'
import { BUNDLED_LANGUAGES, getHighlighter } from 'shiki'

// GitHub Pages serves project sites from /<repo>. The deploy workflow passes the
// right prefix through NEXT_PUBLIC_BASE_PATH (empty when a custom domain is set).
const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''

const withNextra = nextra({
  theme: 'nextra-theme-docs',
  themeConfig: './theme.config.tsx',
  defaultShowCopyCode: true,
  mdxOptions: {
    rehypePrettyCodeOptions: {
      theme: JSON.parse(readFileSync('./public/syntax/mocha.json', 'utf8')),
      getHighlighter: (options) =>
        getHighlighter({
          ...options,
          langs: [
            ...BUNDLED_LANGUAGES,
            {
              id: 'cheeto',
              scopeName: 'source.cheeto',
              aliases: [],
              path: '../../public/syntax/cheeto.tmLanguage.json'
            }
          ]
        })
    }
  }
})

export default withNextra({
  output: 'export',
  basePath,
  images: { unoptimized: true },
  reactStrictMode: true
})
