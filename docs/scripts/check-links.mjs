// Verifies every internal link and #anchor in the exported site points at a
// page and heading that exist. Runs after `next build` against docs/out.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, sep } from 'node:path'

const out = new URL('../out/', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''

function* htmlFiles(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) yield* htmlFiles(path)
    else if (name.endsWith('.html')) yield path
  }
}

const pages = new Map()
for (const file of htmlFiles(out)) {
  let route = '/' + relative(out, file).split(sep).join('/').replace(/\.html$/, '')
  route = route.replace(/\/index$/, '') || '/'
  if (route === '/index') route = '/'
  const html = readFileSync(file, 'utf8')
  const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]))
  pages.set(route, { html, ids })
}

const failures = new Set()
for (const [route, { html }] of pages) {
  for (const [, raw] of html.matchAll(/href="([^"]+)"/g)) {
    const href = raw.replace(/&amp;/g, '&')
    if (/^(https?:|mailto:|data:)/.test(href) || href.startsWith('/_next/')) continue
    if (basePath && href.startsWith(`${basePath}/_next/`)) continue
    let [path, anchor] = href.split('#')
    if (path === '') path = route
    if (basePath) {
      if (!path.startsWith(basePath)) continue
      path = path.slice(basePath.length) || '/'
    }
    if (!path.startsWith('/')) continue
    path = path.replace(/\/$/, '') || '/'
    if (/\.(png|svg|jpg|ico|json|rbxm|xml|txt)$/.test(path)) continue
    const target = pages.get(path)
    if (!target) {
      failures.add(`${route}: missing page ${href}`)
    } else if (anchor && !target.ids.has(decodeURIComponent(anchor))) {
      failures.add(`${route}: missing anchor ${href}`)
    }
  }
}

if (failures.size > 0) {
  console.error(`${failures.size} broken links:\n${[...failures].sort().join('\n')}`)
  process.exit(1)
}
console.log(`Checked links across ${pages.size} pages.`)
