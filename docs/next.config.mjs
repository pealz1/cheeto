import { readFileSync } from 'fs'
import nextra from 'nextra'
import { bundledLanguages, createHighlighter } from 'shiki'

// GitHub Pages serves project sites from /<repo>. The deploy workflow passes the
// right prefix through NEXT_PUBLIC_BASE_PATH (empty when a custom domain is set).
const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'))
const cheeto = { ...readJson('./public/syntax/cheeto.tmLanguage.json'), name: 'cheeto' }

// The highlighter options hold functions, which Turbopack cannot pass to its
// loaders, so the docs build with webpack (see the scripts in package.json).
const withNextra = nextra({
  defaultShowCopyCode: true,
  mdxOptions: {
    rehypePrettyCodeOptions: {
      theme: readJson('./public/syntax/mocha.json'),
      getHighlighter: (options) =>
        createHighlighter({
          ...options,
          langs: [...Object.keys(bundledLanguages).filter((lang) => lang !== 'mermaid'), cheeto]
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
