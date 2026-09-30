// Compiles every ```cheeto example in the docs with the real compiler, so the
// docs cannot show syntax that does not parse. Blocks tagged `nocheck` (for
// fragments that only make sense next to another block) are skipped.
//
// Usage, from the repository root: node docs/scripts/check-examples.mjs
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'

const root = process.cwd()
const pagesDir = join(root, 'docs', 'pages')
const declaration = /^(export\s+)?(event|function|channel|type|struct|enum|map|set|scope)\s/m
const header = 'option ClientOutput = "out/Client.luau"\noption ServerOutput = "out/Server.luau"\n'

function* mdxFiles(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) yield* mdxFiles(path)
    else if (name.endsWith('.mdx')) yield path
  }
}

function* blocks(source) {
  const fence = /```cheeto([^\n]*)\n([\s\S]*?)```/g
  let match
  while ((match = fence.exec(source))) {
    yield { meta: match[1], code: match[2], line: source.slice(0, match.index).split('\n').length }
  }
}

const work = mkdtempSync(join(tmpdir(), 'cheeto-docs-'))
let checked = 0
const failures = []

for (const file of mdxFiles(pagesDir)) {
  for (const block of blocks(readFileSync(file, 'utf8'))) {
    if (block.meta.includes('nocheck') || !declaration.test(block.code) || /^\s*import\s/m.test(block.code)) continue
    const hasOutput = /option\s+ClientOutput/.test(block.code)
    const options = (block.code.match(/^option .*$/gm) ?? []).filter((line) => !/TypesOutput/.test(line))
    const body = block.code.replace(/^option .*$/gm, '')
    const source = `${hasOutput ? '' : header}${options.join('\n')}\n${body}`
    const schema = join(work, `example${checked}.cheeto`)
    writeFileSync(schema, source)
    checked += 1
    try {
      const output = execFileSync('lune', ['run', 'src/CLI/init.luau', schema.replace(/\.cheeto$/, ''), '--', '--yes'], {
        cwd: root,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe']
      })
      if (!output.includes('Network files generated')) throw new Error(output)
    } catch (error) {
      const text = String(error.stderr || error.stdout || error.message)
      failures.push(`${relative(root, file)}:${block.line}\n${text.split('\n').slice(0, 12).join('\n')}`)
    }
  }
}

if (failures.length > 0) {
  console.error(`${failures.length} of ${checked} cheeto examples failed to compile:\n`)
  console.error(failures.join('\n\n'))
  process.exit(1)
}
console.log(`All ${checked} cheeto examples compile.`)
