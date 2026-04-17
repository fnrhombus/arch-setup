// scripts/runbook-pdf.mjs
//
// Renders INSTALL-RUNBOOK.md to a 5.5" x 8.5" PDF with 0.5" margins
// and a 12pt body font. Uses `marked` for MD→HTML and Edge headless
// (--print-to-pdf) so there's no Puppeteer install.
//
// Run once: `pnpm dlx marked@latest --version >/dev/null` to warm cache, then
// `node scripts/runbook-pdf.mjs`. Or invoke via `pnpm pdf` if wired up.

import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { marked } from 'marked';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');

const mdPath = join(repoRoot, 'runbook', 'INSTALL-RUNBOOK.md');
const pdfPath = join(repoRoot, 'runbook', 'INSTALL-RUNBOOK.pdf');
const md = readFileSync(mdPath, 'utf8');

marked.setOptions({ gfm: true, breaks: false, headerIds: false, mangle: false });
const body = marked.parse(md);

const css = `
@page {
    size: 5.5in 8.5in;
    margin: 0.5in;
}
html { font-size: 12pt; }
body {
    font-family: "Segoe UI", "Helvetica Neue", Arial, sans-serif;
    font-size: 12pt;
    line-height: 1.35;
    color: #111;
    margin: 0;
    padding: 0;
    word-wrap: break-word;
}
h1 { font-size: 18pt; margin: 0 0 0.3em; page-break-before: always; page-break-after: avoid; }
h1:first-of-type { page-break-before: avoid; }
h2 { font-size: 15pt; margin: 1em 0 0.3em; page-break-after: avoid; }
h3 { font-size: 13pt; margin: 0.9em 0 0.25em; page-break-after: avoid; }
h4 { font-size: 12pt; margin: 0.8em 0 0.2em; page-break-after: avoid; }
p { margin: 0.3em 0 0.6em; }
ul, ol { margin: 0.3em 0 0.6em 1.2em; padding: 0; }
li { margin: 0.1em 0; }
code {
    font-family: "Cascadia Mono", "Consolas", "Courier New", monospace;
    font-size: 10.5pt;
    background: #f2f2f2;
    padding: 1px 3px;
    border-radius: 3px;
    word-break: break-all;
}
pre {
    background: #f6f6f6;
    border: 1px solid #ddd;
    border-radius: 4px;
    padding: 6pt 8pt;
    font-size: 9.5pt;
    line-height: 1.25;
    overflow: hidden;
    white-space: pre-wrap;
    word-break: break-word;
    page-break-inside: avoid;
}
pre code { background: transparent; padding: 0; font-size: inherit; }
blockquote {
    margin: 0.5em 0;
    padding: 0 0 0 10pt;
    border-left: 3px solid #ccc;
    color: #333;
}
table { border-collapse: collapse; margin: 0.6em 0; font-size: 10.5pt; width: 100%; }
th, td { border: 1px solid #bbb; padding: 3pt 6pt; vertical-align: top; text-align: left; }
th { background: #eee; }
hr { border: none; border-top: 1px solid #ccc; margin: 1em 0; }
a { color: #06c; text-decoration: none; word-break: break-all; }
img { max-width: 100%; }
strong { font-weight: 600; }
`;

const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>INSTALL-RUNBOOK</title>
<style>${css}</style>
</head>
<body>
${body}
</body>
</html>
`;

const tmp = mkdtempSync(join(tmpdir(), 'runbook-pdf-'));
const htmlPath = join(tmp, 'runbook.html');
writeFileSync(htmlPath, html, 'utf8');

// Launch Edge headless; --print-to-pdf honors @page size/margins from CSS.
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const args = [
    '--headless=new',
    '--disable-gpu',
    '--no-pdf-header-footer',
    `--print-to-pdf=${pdfPath}`,
    `file:///${htmlPath.replace(/\\/g, '/')}`,
];

const res = spawnSync(edge, args, { stdio: 'inherit' });
if (res.status !== 0) {
    console.error(`Edge headless exited with status ${res.status}`);
    process.exit(res.status ?? 1);
}

rmSync(tmp, { recursive: true, force: true });
console.log(`wrote ${pdfPath}`);
