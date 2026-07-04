import { readFileSync } from 'fs'
import nextra from 'nextra'
import { BUNDLED_LANGUAGES, getHighlighter } from 'shiki'

const withNextra = nextra({
  theme: 'nextra-theme-docs',
  themeConfig: './theme.config.tsx',
  mdxOptions: {
     rehypePrettyCodeOptions: {
      theme: JSON.parse(
        readFileSync('./public/syntax/mocha.json', 'utf8')
      ),
      getHighlighter: options =>
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
  output: "export",
  basePath: "/cheeto",
  images: {unoptimized: true}
})
