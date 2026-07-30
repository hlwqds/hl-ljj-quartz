# HTML Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a restrained, ATS-friendly, two-page A4 HTML resume and export a matching two-page PDF.

**Architecture:** Use one self-contained semantic HTML file with embedded print CSS and a local photo asset. Represent each printed page as an explicit `.page` element so screen preview and browser PDF pagination are deterministic.

**Tech Stack:** HTML5, CSS print media, local static HTTP server, Browser/IAB visual QA, Chromium PDF export.

---

### Task 1: Create the self-contained resume

**Files:**

- Create: `docs/黄琳-Linux内核与高性能网络研发工程师-2026.html`
- Create: `docs/assets/huanglin-resume-photo.jpg`

- [ ] Copy and crop the existing resume photo into `docs/assets/huanglin-resume-photo.jpg`.
- [ ] Create semantic HTML containing two `.page` sections.
- [ ] Add CSS variables for typography, spacing, colors and A4 geometry.
- [ ] Add screen CSS that displays pages on a neutral preview canvas.
- [ ] Add `@media print` CSS with zero browser margin and exact A4 page breaks.
- [ ] Include all confirmed resume content and external links.

### Task 2: Validate HTML structure

**Files:**

- Test: `docs/黄琳-Linux内核与高性能网络研发工程师-2026.html`

- [ ] Parse the HTML and verify exactly two `.page` elements exist.
- [ ] Verify the photo asset and all required headings are present.
- [ ] Verify key metrics `100–220 ns/包`, `110%`, and `50%` are present.
- [ ] Verify there are no remote font or script dependencies.

Run:

```bash
python3 -c 'from bs4 import BeautifulSoup; ...'
```

Expected: two pages and all required assertions pass.

### Task 3: Render and visually inspect

**Files:**

- Modify if needed: `docs/黄琳-Linux内核与高性能网络研发工程师-2026.html`

- [ ] Start a local static server from the repository root.
- [ ] Open the HTML through Browser/IAB.
- [ ] Verify page identity, meaningful DOM content and console health.
- [ ] Capture full-page visual evidence.
- [ ] Inspect typography, whitespace, photo sizing, line wrapping and page boundaries.
- [ ] Adjust CSS until both A4 pages are balanced and no content clips.

### Task 4: Export and verify PDF

**Files:**

- Create: `docs/黄琳-Linux内核与高性能网络研发工程师-2026.pdf`

- [ ] Print the HTML using Chromium with backgrounds enabled and zero margins.
- [ ] Verify the PDF is exactly two A4 pages.
- [ ] Extract PDF text and confirm key project names and metrics are preserved.
- [ ] Render the PDF pages to images and perform a final visual comparison with the HTML.
