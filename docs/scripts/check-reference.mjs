// Fails when the reference drifts from the compiler: every option, endpoint
// field, runtime namespace member and drop reason in src/ must have an entry,
// and the docs must not reference Network.* members that do not exist.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

const docs = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const src = join(docs, '..', 'src')
const pages = join(docs, 'content')
const read = (path) => readFileSync(path, 'utf8')
const failures = []

function* mdxFiles(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) yield* mdxFiles(path)
    else if (name.endsWith('.mdx')) yield path
  }
}

const headings = (text) => new Set([...text.matchAll(/^#{2,3} `?([A-Za-z0-9]+)`?/gm)].map((match) => match[1]))

// Options
const parser = read(join(src, 'Parser.luau'))
const optionBlock = parser.match(/local OPTIONS[^{]*\{([\s\S]*?)\n\}/)[1]
const options = [...optionBlock.matchAll(/^\s+([A-Za-z0-9]+) = "/gm)].map((match) => match[1])
const removed = new Set(['ProtocolMode', 'AcceptProtocolVersion1'])
const optionDir = join(pages, 'reference', 'options')
const optionHeadings = new Set()
for (const file of readdirSync(optionDir)) {
  if (file.endsWith('.mdx') && file !== 'overview.mdx') {
    for (const heading of headings(read(join(optionDir, file)))) optionHeadings.add(heading)
  }
}
for (const option of options) {
  if (!removed.has(option) && !optionHeadings.has(option)) failures.push(`option ${option} has no entry in reference/options`)
}
const overview = read(join(optionDir, 'overview.mdx'))
for (const option of options) {
  if (!overview.includes(`\`${option}\``)) failures.push(`option ${option} is missing from reference/options/overview`)
}

// Endpoint fields
const fieldsPage = headings(read(join(pages, 'reference', 'fields.mdx')))
for (const table of ['EVENT', 'FUNCTION', 'CHANNEL']) {
  const block = parser.match(new RegExp(`local ${table}: \\{ EventOption \\} = \\{([\\s\\S]*?)\\n\\}`))[1]
  for (const [, key] of block.matchAll(/Key = "([A-Za-z]+)"/g)) {
    if (!fieldsPage.has(key)) failures.push(`${table.toLowerCase()} field ${key} has no entry in reference/fields`)
  }
}

// Runtime namespaces
const generator = read(join(src, 'Generator', 'init.luau'))
const pushBlock = generator.match(/local function PushRuntimeApi[\s\S]*?\nend\n/)[0]
const namespaces = new Map()
const rootMembers = new Set()
let current = null
for (const line of pushBlock.split('\n')) {
  const push = line.match(/Target\.Push\(`([A-Za-z]+) = /)
  if (line.includes('Target.Push(`}),`')) {
    current = null
  } else if (push && line.includes('table.freeze')) {
    current = push[1]
    namespaces.set(current, new Set())
  } else if (push) {
    ;(current ? namespaces.get(current) : rootMembers).add(push[1])
  }
}
namespaces.get('Connection')?.delete('new')
const apiDir = join(pages, 'reference', 'api')
for (const [namespace, members] of namespaces) {
  const file = join(apiDir, `${namespace.toLowerCase()}.mdx`)
  let page
  try {
    page = headings(read(file))
  } catch {
    failures.push(`namespace ${namespace} has no page reference/api/${namespace.toLowerCase()}.mdx`)
    continue
  }
  for (const member of members) {
    if (!page.has(member)) failures.push(`${namespace}.${member} has no entry in reference/api/${namespace.toLowerCase()}.mdx`)
  }
}
const modulePage = headings(read(join(apiDir, 'module.mdx')))
for (const member of [...rootMembers, 'StepReplication']) {
  if (member !== 'Connection' && !modulePage.has(member)) failures.push(`module member ${member} has no entry in reference/api/module.mdx`)
}

// Drop reasons
const base = read(join(src, 'Templates', 'Base.luau'))
const errorBlock = base.match(/local TransportError = table\.freeze\(\{([\s\S]*?)\}\)/)[1]
const dropPage = read(join(pages, 'reference', 'drop-reasons.mdx'))
for (const [, reason] of errorBlock.matchAll(/^\s+([A-Za-z]+) = "/gm)) {
  if (!dropPage.includes(`\`${reason}\``)) failures.push(`drop reason ${reason} is missing from reference/drop-reasons`)
}

// Network.Namespace.Member references anywhere in the docs
for (const file of mdxFiles(pages)) {
  for (const [, namespace, member] of read(file).matchAll(/Network\.([A-Z][A-Za-z]+)\.([A-Z][A-Za-z]+)/g)) {
    const known = namespaces.get(namespace)
    if (known && !known.has(member) && !(namespace === 'Connection' && member === 'new')) {
      failures.push(`${file.slice(pages.length + 1)} mentions Network.${namespace}.${member}, which does not exist`)
    }
  }
}

if (failures.length > 0) {
  console.error(`Reference is out of date with the compiler (${failures.length}):\n- ${failures.join('\n- ')}`)
  process.exit(1)
}
console.log(`Reference covers ${options.length} options, ${namespaces.size} namespaces and every drop reason.`)
