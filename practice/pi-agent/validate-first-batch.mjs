import fs from "node:fs"
import path from "node:path"
import process from "node:process"

const root = path.resolve(import.meta.dirname, "../..")
const contentDir = path.join(root, "content")
const labDir = path.join(root, "practice/pi-agent")

const articles = [
  "2026-06-12-pi-agent-deep-dive-series-index.md",
  "2026-06-12-pi-agent-deep-dive-ch01-overview.md",
  "2026-06-12-pi-agent-deep-dive-ch02-installation-providers.md",
  "2026-06-12-pi-agent-deep-dive-ch03-tui-modes-queue.md",
  "2026-06-12-pi-agent-deep-dive-ch04-sessions-branching-compaction.md",
  "2026-06-12-pi-agent-deep-dive-ch05-monorepo-architecture.md",
]

const labFiles = [
  "README.md",
  "phase-1-environment/README.md",
  "phase-1-environment/check-environment.sh",
]

const expectedSlugs = new Set(articles.map((file) => file.slice(0, -3)))
const errors = []

function report(message) {
  errors.push(message)
}

function parseFrontmatter(file, source) {
  const match = source.match(/^---\n([\s\S]*?)\n---(?:\n|$)/)
  if (!match) {
    report(`${file}: missing YAML frontmatter`)
    return ""
  }

  const frontmatter = match[1]
  for (const field of ["title", "date", "tags"]) {
    if (!new RegExp(`^${field}:\\s*\\S`, "m").test(frontmatter)) {
      report(`${file}: missing frontmatter field "${field}"`)
    }
  }
  return frontmatter
}

function checkPermalinks(file, source) {
  const githubBlobUrls = source.matchAll(
    /https:\/\/github\.com\/earendil-works\/pi\/blob\/([^/\s)]+)\//g,
  )

  for (const match of githubBlobUrls) {
    if (!/^[0-9a-f]{40}$/.test(match[1])) {
      report(`${file}: GitHub blob URL does not use a full commit SHA: ${match[0]}`)
    }
  }
}

function checkWikiLinks(file, source) {
  const links = source.matchAll(/\[\[([^|\]#]+)(?:[|#][^\]]*)?\]\]/g)
  for (const match of links) {
    const target = match[1].replace(/\\$/, "")
    if (target.includes("pi-agent-deep-dive") && !expectedSlugs.has(target)) {
      report(`${file}: unresolved first-batch Wiki link "${target}"`)
    }
  }
}

for (const file of articles) {
  const fullPath = path.join(contentDir, file)
  if (!fs.existsSync(fullPath)) {
    report(`${file}: missing article`)
    continue
  }

  const source = fs.readFileSync(fullPath, "utf8")
  parseFrontmatter(file, source)
  if (!/[0-9a-f]{40}/.test(source)) {
    report(`${file}: missing 40-character upstream commit SHA`)
  }
  checkPermalinks(file, source)
  checkWikiLinks(file, source)
}

for (const file of labFiles) {
  const fullPath = path.join(labDir, file)
  if (!fs.existsSync(fullPath)) {
    report(`practice/pi-agent/${file}: missing lab file`)
  }
}

const checkerPath = path.join(labDir, "phase-1-environment/check-environment.sh")
if (fs.existsSync(checkerPath)) {
  const source = fs.readFileSync(checkerPath, "utf8")
  const forbidden = [
    [/\b(?:npm|pnpm|yarn|bun)\s+(?:install|add)\b/, "package installation"],
    [/\bpi\s+\/?login\b/, "provider login"],
    [/\bsudo\b/, "sudo"],
    [/(?:^|\s)(?:rm|mv)\s+[^#\n]*(?:~\/|\$HOME)/m, "destructive home-directory command"],
    [/(?:auth\.json|settings\.json|trust\.json).*(?:>|tee|write)/i, "credential/config write"],
  ]

  for (const [pattern, label] of forbidden) {
    if (pattern.test(source)) {
      report(`check-environment.sh: contains forbidden ${label}`)
    }
  }
}

if (errors.length > 0) {
  for (const error of errors) {
    console.error(`[FAIL] ${error}`)
  }
  console.error(`\n${errors.length} validation error(s)`)
  process.exit(1)
}

console.log(`[PASS] ${articles.length} Pi Agent articles validated`)
console.log(`[PASS] ${labFiles.length} environment lab files validated`)
