// Type-checks the TypeScript definitions generated for the test schema, so the
// .d.ts output cannot regress into something roblox-ts rejects.
//
// Usage, from the repository root: node docs/scripts/check-typescript.mjs
import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

const root = process.cwd()
const run = (command, args, options = {}) =>
  execFileSync(command, args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], shell: process.platform === 'win32', ...options })

run('lune', ['run', 'src/CLI/init.luau', 'test/Sources/Test', '--', '--yes'])

const local = join(root, 'docs', 'node_modules', '.bin', process.platform === 'win32' ? 'tsc.cmd' : 'tsc')
const [command, prefix] = existsSync(local) ? [local, []] : ['npx', ['--yes', '-p', 'typescript@5', 'tsc']]
const files = ['Network/Client.d.ts', 'Network/Server.d.ts']

try {
  run(command, [...prefix, '--noEmit', '--strict', '--lib', 'es2020', ...files])
} catch (error) {
  console.error(`Generated TypeScript definitions do not type-check:\n${error.stdout || ''}${error.stderr || ''}`)
  process.exit(1)
}
console.log(`Generated TypeScript definitions type-check (${files.join(', ')}).`)
