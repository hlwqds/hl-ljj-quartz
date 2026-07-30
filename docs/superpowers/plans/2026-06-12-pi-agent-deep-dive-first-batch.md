# Pi Agent Deep Dive First Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the Pi Agent series index, chapters 1-5, a read-only environment lab, and a homepage entry, all verified against a current `earendil-works/pi` `main` commit.

**Architecture:** Treat a temporary clone of upstream Pi as the factual source and record its full commit SHA in every source-sensitive article. Keep prose in Quartz `content/`, keep runnable checks under `practice/pi-agent/`, and use a small validation script to verify frontmatter, internal links, source permalinks, and the non-mutating lab contract before running the full Quartz build.

**Tech Stack:** Markdown, Quartz v4 Wiki links, Bash, Node.js 22+, Git, npm/pnpm.

---

## File Structure

- Create `content/2026-06-12-pi-agent-deep-dive-series-index.md`: six-part learning map and chapter status.
- Create `content/2026-06-12-pi-agent-deep-dive-ch01-overview.md`: product positioning, boundaries, and philosophy.
- Create `content/2026-06-12-pi-agent-deep-dive-ch02-installation-providers.md`: package/source setup, authentication, providers, and diagnostics.
- Create `content/2026-06-12-pi-agent-deep-dive-ch03-tui-modes-queue.md`: operating modes, TUI, shortcuts, and message queue.
- Create `content/2026-06-12-pi-agent-deep-dive-ch04-sessions-branching-compaction.md`: session tree, resume, branching, and compaction.
- Create `content/2026-06-12-pi-agent-deep-dive-ch05-monorepo-architecture.md`: four-package architecture and one-request data flow.
- Create `practice/pi-agent/README.md`: lab index and safety contract.
- Create `practice/pi-agent/phase-1-environment/README.md`: package and source workflows, expected output, and cleanup.
- Create `practice/pi-agent/phase-1-environment/check-environment.sh`: read-only prerequisite and optional Pi CLI checks.
- Create `practice/pi-agent/validate-first-batch.mjs`: deterministic first-batch content checks.
- Modify `content/index.md`: add the Pi Agent series entry without changing existing sections.

### Task 1: Capture The Upstream Evidence Baseline

**Files:**

- Create: `/tmp/pi-agent-doc-source/` as an untracked temporary clone
- Reference: `docs/superpowers/specs/2026-06-12-pi-agent-deep-dive-series-design.md`

- [ ] **Step 1: Clone the current upstream `main` branch**

Run:

```bash
rm -rf /tmp/pi-agent-doc-source
git clone --depth 1 --branch main https://github.com/earendil-works/pi.git /tmp/pi-agent-doc-source
```

Expected: clone completes with no authentication prompt.

- [ ] **Step 2: Record the exact source baseline**

Run:

```bash
git -C /tmp/pi-agent-doc-source rev-parse HEAD
git -C /tmp/pi-agent-doc-source show -s --format='%H%n%cI%n%s' HEAD
```

Expected: a 40-character SHA, commit timestamp, and subject. Use this SHA in all five articles and all GitHub source permalinks.

- [ ] **Step 3: Build the evidence checklist**

Inspect these upstream documents and sources:

```bash
sed -n '1,240p' /tmp/pi-agent-doc-source/README.md
find /tmp/pi-agent-doc-source/packages/coding-agent/docs -maxdepth 1 -type f -print | sort
sed -n '1,240p' /tmp/pi-agent-doc-source/packages/coding-agent/docs/quickstart.md
sed -n '1,280p' /tmp/pi-agent-doc-source/packages/coding-agent/docs/usage.md
sed -n '1,260p' /tmp/pi-agent-doc-source/packages/coding-agent/docs/providers.md
sed -n '1,280p' /tmp/pi-agent-doc-source/packages/coding-agent/docs/sessions.md
sed -n '1,280p' /tmp/pi-agent-doc-source/packages/coding-agent/docs/compaction.md
sed -n '1,260p' /tmp/pi-agent-doc-source/packages/coding-agent/docs/tui.md
sed -n '1,220p' /tmp/pi-agent-doc-source/packages/coding-agent/src/index.ts
sed -n '1,260p' /tmp/pi-agent-doc-source/packages/agent/src/agent-loop.ts
```

Expected: enough primary evidence to support installation, modes, sessions, compaction, and package boundaries. If upstream paths differ, locate the equivalent with `rg --files /tmp/pi-agent-doc-source/packages`.

- [ ] **Step 4: Confirm current package names and Node requirement**

Run:

```bash
node -e '
const fs = require("fs");
for (const path of process.argv.slice(1)) {
  const p = JSON.parse(fs.readFileSync(path, "utf8"));
  console.log(path, p.name, p.version, p.engines?.node ?? "");
}
' /tmp/pi-agent-doc-source/packages/*/package.json
```

Expected: package names and supported Node versions are taken from current upstream metadata, not from the neighboring GSD fork.

### Task 2: Add A Failing First-Batch Validator

**Files:**

- Create: `practice/pi-agent/validate-first-batch.mjs`

- [ ] **Step 1: Add the validator**

Create a Node.js script that:

1. defines the expected index and five chapter paths;
2. asserts every expected article exists;
3. parses the frontmatter delimiters and checks `title`, `date`, and `tags`;
4. checks each chapter contains a 40-character upstream commit SHA;
5. checks every GitHub `/blob/<sha>/` URL uses a full SHA;
6. resolves Wiki links targeting the first-batch slugs;
7. checks `check-environment.sh` does not contain package installation, credential writes, `sudo`, or destructive home-directory commands;
8. exits non-zero with one error per line when any assertion fails.

Use only Node built-ins: `node:fs`, `node:path`, and `node:process`.

- [ ] **Step 2: Run the validator and verify the missing-file failure**

Run:

```bash
node practice/pi-agent/validate-first-batch.mjs
```

Expected: FAIL, listing the six missing article files and missing lab files.

- [ ] **Step 3: Commit the validator**

```bash
git add practice/pi-agent/validate-first-batch.mjs
git commit -m "test: add Pi Agent first batch validator"
```

### Task 3: Write The Series Index

**Files:**

- Create: `content/2026-06-12-pi-agent-deep-dive-series-index.md`

- [ ] **Step 1: Write valid Quartz frontmatter**

Use:

```yaml
---
title: "Pi Agent 深度探索系列索引"
date: 2026-06-12 00:00:00
pin: true
description: "从日常使用、Agent Loop、四个核心包源码到 Extension 与 SDK 二次开发的 Pi Agent 系统学习路径"
tags: [pi-agent, coding-agent, llm, agent, series, index]
---
```

- [ ] **Step 2: Add the learning contract and source policy**

Include:

- target reader and post-read abilities;
- six-part, 30-chapter table;
- completed status for chapters 1-5 and planned status for 6-30;
- exact source SHA and verification date;
- explicit warning that `main` is moving and Pi is not a default security sandbox;
- links to upstream repository and `practice/pi-agent/README.md`.

- [ ] **Step 3: Link the completed chapters**

Use these exact Wiki-link targets:

```text
[[2026-06-12-pi-agent-deep-dive-ch01-overview|第一章]]
[[2026-06-12-pi-agent-deep-dive-ch02-installation-providers|第二章]]
[[2026-06-12-pi-agent-deep-dive-ch03-tui-modes-queue|第三章]]
[[2026-06-12-pi-agent-deep-dive-ch04-sessions-branching-compaction|第四章]]
[[2026-06-12-pi-agent-deep-dive-ch05-monorepo-architecture|第五章]]
```

- [ ] **Step 4: Run the validator**

Run:

```bash
node practice/pi-agent/validate-first-batch.mjs
```

Expected: index-related checks pass; chapter and lab missing-file errors remain.

### Task 4: Write Chapters 1 And 2

**Files:**

- Create: `content/2026-06-12-pi-agent-deep-dive-ch01-overview.md`
- Create: `content/2026-06-12-pi-agent-deep-dive-ch02-installation-providers.md`

- [ ] **Step 1: Write chapter 1**

Cover:

- Pi as a terminal-native, extensible coding-agent harness;
- what it includes and deliberately leaves replaceable;
- comparison table: Pi, IDE coding assistant, closed coding agent, generic agent framework;
- four operating surfaces at a high level;
- permission boundary and suitable/unsuitable scenarios;
- a “read next” link to chapter 2.

Support source-sensitive claims with full-SHA README or documentation permalinks.

- [ ] **Step 2: Write chapter 2**

Cover:

- prerequisites from current package metadata;
- global/package-runner installation path from current quickstart;
- source clone, dependency install, build, and local execution path;
- provider authentication categories: environment key, OAuth/login, cloud credential chain, custom endpoint;
- model selection and minimal diagnostics;
- a decision table for package use versus source use;
- no real secret values and no global mutation in the lab;
- a “read next” link to chapter 3.

- [ ] **Step 3: Check commands against the upstream tree**

Run every non-authenticating command that does not mutate global state. For commands requiring a provider key, verify syntax against docs and mark the expected authentication failure instead of inserting credentials.

- [ ] **Step 4: Run formatting and validator checks**

Run:

```bash
npx prettier --check \
  content/2026-06-12-pi-agent-deep-dive-ch01-overview.md \
  content/2026-06-12-pi-agent-deep-dive-ch02-installation-providers.md
node practice/pi-agent/validate-first-batch.mjs
```

Expected: Prettier passes; only chapters 3-5 and lab files remain missing.

- [ ] **Step 5: Commit chapters 1 and 2 with the index**

```bash
git add \
  content/2026-06-12-pi-agent-deep-dive-series-index.md \
  content/2026-06-12-pi-agent-deep-dive-ch01-overview.md \
  content/2026-06-12-pi-agent-deep-dive-ch02-installation-providers.md
git commit -m "docs: add Pi Agent introduction and setup guides"
```

### Task 5: Write Chapters 3 And 4

**Files:**

- Create: `content/2026-06-12-pi-agent-deep-dive-ch03-tui-modes-queue.md`
- Create: `content/2026-06-12-pi-agent-deep-dive-ch04-sessions-branching-compaction.md`

- [ ] **Step 1: Write chapter 3**

Cover:

- Interactive, Print, JSON, and RPC modes from current CLI docs;
- mode-selection table;
- TUI regions and editor behavior;
- current essential shortcuts and commands;
- steering/follow-up queue semantics while generation is active;
- interruption and safe exit behavior;
- “read next” link to chapter 4.

Do not infer shortcut behavior from the GSD fork. Verify each command and keybinding in current upstream docs or source.

- [ ] **Step 2: Write chapter 4**

Cover:

- session persistence and JSONL/tree mental model;
- creating, resuming, branching, and navigating sessions;
- distinction between conversation state, model context, and persisted session history;
- automatic and manual compaction;
- compaction trade-offs and recovery limitations;
- a Mermaid lifecycle diagram;
- “read next” link to chapter 5.

- [ ] **Step 3: Run formatting and validator checks**

Run:

```bash
npx prettier --check \
  content/2026-06-12-pi-agent-deep-dive-ch03-tui-modes-queue.md \
  content/2026-06-12-pi-agent-deep-dive-ch04-sessions-branching-compaction.md
node practice/pi-agent/validate-first-batch.mjs
```

Expected: Prettier passes; only chapter 5 and lab files remain missing.

- [ ] **Step 4: Commit chapters 3 and 4**

```bash
git add \
  content/2026-06-12-pi-agent-deep-dive-ch03-tui-modes-queue.md \
  content/2026-06-12-pi-agent-deep-dive-ch04-sessions-branching-compaction.md
git commit -m "docs: explain Pi modes sessions and compaction"
```

### Task 6: Write Chapter 5

**Files:**

- Create: `content/2026-06-12-pi-agent-deep-dive-ch05-monorepo-architecture.md`

- [ ] **Step 1: Verify upstream package boundaries**

Read each core package `package.json`, README, public exports, and primary entry point:

```bash
for package in ai agent tui coding-agent; do
  sed -n '1,220p' "/tmp/pi-agent-doc-source/packages/$package/package.json"
  test ! -f "/tmp/pi-agent-doc-source/packages/$package/README.md" ||
    sed -n '1,240p' "/tmp/pi-agent-doc-source/packages/$package/README.md"
done
```

Expected: package names, dependency direction, and public entry points are known from upstream.

- [ ] **Step 2: Write the architecture chapter**

Include:

- responsibility and non-responsibility table for all four packages;
- dependency diagram based on actual package metadata;
- one-request sequence from user input through model stream, tool execution, state update, and terminal render;
- public API versus internal implementation distinction;
- a source-reading route for chapters 11-20;
- link back to the series index.

- [ ] **Step 3: Run formatting and validator checks**

Run:

```bash
npx prettier --check content/2026-06-12-pi-agent-deep-dive-ch05-monorepo-architecture.md
node practice/pi-agent/validate-first-batch.mjs
```

Expected: article checks pass; only lab files remain missing.

- [ ] **Step 4: Commit chapter 5**

```bash
git add content/2026-06-12-pi-agent-deep-dive-ch05-monorepo-architecture.md
git commit -m "docs: map Pi Agent monorepo architecture"
```

### Task 7: Add The Read-Only Environment Lab

**Files:**

- Create: `practice/pi-agent/README.md`
- Create: `practice/pi-agent/phase-1-environment/README.md`
- Create: `practice/pi-agent/phase-1-environment/check-environment.sh`

- [ ] **Step 1: Write the environment checker**

The Bash script must:

- use `set -uo pipefail`;
- check `node`, `npm`, and `git` as required commands;
- check `pnpm` and `pi` as optional commands;
- compare the detected Node major/minor version with current upstream `engines.node`;
- print one `[PASS]`, `[FAIL]`, or `[SKIP]` line per check;
- print detected command paths and versions;
- never install packages, invoke provider login, write config, or modify the user home directory;
- exit `1` only when required prerequisites fail.

- [ ] **Step 2: Write the lab documentation**

Document:

```bash
cd practice/pi-agent/phase-1-environment
bash check-environment.sh
```

Include representative output, package-runner workflow, source-clone workflow, authentication handoff, and cleanup limited to user-created temporary clone directories.

- [ ] **Step 3: Write the lab index**

Explain the phased lab layout and mark only `phase-1-environment` as available.

- [ ] **Step 4: Validate the shell script**

Run:

```bash
bash -n practice/pi-agent/phase-1-environment/check-environment.sh
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck practice/pi-agent/phase-1-environment/check-environment.sh
fi
bash practice/pi-agent/phase-1-environment/check-environment.sh
```

Expected: syntax passes; ShellCheck reports no findings when installed; the script prints status lines and performs no writes.

- [ ] **Step 5: Run the first-batch validator**

Run:

```bash
node practice/pi-agent/validate-first-batch.mjs
```

Expected: PASS with a summary naming six articles and the environment lab.

- [ ] **Step 6: Commit the lab**

```bash
git add practice/pi-agent
git commit -m "docs: add Pi Agent environment lab"
```

### Task 8: Wire Navigation And Verify The Published Surface

**Files:**

- Modify: `content/index.md`

- [ ] **Step 1: Add the homepage entry**

Add a new section after the introduction:

```markdown
## AI Agent 与开发工具

- [[2026-06-12-pi-agent-deep-dive-series-index|Pi Agent 深度探索系列]]
```

Preserve the existing “高性能网络与 I/O” section and its links.

- [ ] **Step 2: Run focused validation**

Run:

```bash
node practice/pi-agent/validate-first-batch.mjs
npx prettier --check \
  content/index.md \
  content/2026-06-12-pi-agent-deep-dive-*.md \
  practice/pi-agent/**/*.md \
  practice/pi-agent/validate-first-batch.mjs
git diff --check
```

Expected: all commands pass.

- [ ] **Step 3: Build Quartz**

Run:

```bash
npx quartz build
```

Expected: exit code `0`, with generated pages for the index and chapters 1-5 and no broken-link failure.

- [ ] **Step 4: Cold-read the published content**

Read the generated pages or source documents in order and verify:

- a fresh reader can choose package or source setup;
- no step assumes credentials already exist;
- session, context, and compaction are not conflated;
- package responsibilities agree with current upstream metadata;
- every source-sensitive claim has a stable permalink;
- no article claims Pi is a security sandbox.

Fix any gap and rerun Steps 2-3.

- [ ] **Step 5: Inspect scope**

Run:

```bash
git status --short
git diff --stat HEAD~4
git diff -- content/index.md content/2026-06-12-pi-agent-deep-dive-*.md practice/pi-agent
```

Expected: only the planned Pi files and the homepage entry are part of this implementation; pre-existing unrelated changes remain untouched.

- [ ] **Step 6: Commit navigation**

```bash
git add content/index.md
git commit -m "docs: link Pi Agent series from homepage"
```
