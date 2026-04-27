// scripts/fetch-win11-hash.mjs
//
// Drives the official Microsoft Windows 11 download page via Playwright
// and extracts the SHA-256 hash for the multi-edition English x64 ISO.
// The hash sits behind a JS-rendered "Verify your download" link — static
// HTML scraping (curl + regex) doesn't see it, so we run a real browser.
//
// Use when the in-git sidecar (assets/Win11_*.iso.sha256) drifts: Fido
// pulled a newer build than what we last recorded, or the local copy got
// corrupted. fetch-assets.ps1's soft-warn message tells the user to run
// this script.
//
// Run:
//   pnpm hash:win11             # print the hash
//   pnpm hash:win11 --update    # also overwrite assets/Win11_*.iso.sha256
//
// Requires `playwright` (devDependency) — installed by `pnpm i`. Browser
// binaries are pulled by Playwright's own postinstall.

import { chromium } from 'playwright';
import { writeFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot  = dirname(__dirname);
const assetsDir = join(repoRoot, 'assets');

const MS_URL    = 'https://www.microsoft.com/software-download/windows11';
const EDITION   = 'Windows 11 (multi-edition ISO for x64 devices)';
const LANGUAGE  = 'English (United States)';

async function fetchHashSection() {
    console.log(`[info] launching Chromium (headless)...`);
    const browser = await chromium.launch({ headless: true });
    try {
        const page = await browser.newPage();
        console.log(`[info] navigating to ${MS_URL} ...`);
        await page.goto(MS_URL, { waitUntil: 'domcontentloaded' });

        // 1. Edition dropdown
        await page.waitForSelector('#product-edition', { timeout: 30_000 });
        await page.selectOption('#product-edition', { label: EDITION });
        await page.click('#submit-product-edition');

        // 2. Language dropdown
        await page.waitForSelector('#product-languages', { timeout: 30_000 });
        await page.selectOption('#product-languages', { label: LANGUAGE });
        await page.click('#submit-sku');

        // 3. "Verify your download" link reveals the hash table
        const verifyLink = page.locator('a:has-text("Verify your download")');
        await verifyLink.waitFor({ timeout: 30_000 });
        await verifyLink.click();

        // 4. Hash container
        const hashContainer = page.locator('.product-verification-container');
        await hashContainer.waitFor({ timeout: 30_000 });
        return (await hashContainer.innerText()).trim();
    } finally {
        await browser.close();
    }
}

function extractSha256(text) {
    // The hash table lists multiple SKUs (Pro, Home, Enterprise, etc.).
    // For the multi-edition consumer ISO there's typically one row; if
    // multiple 64-hex strings appear, prefer the one whose row text
    // mentions our canonical filename pattern.
    const lines = text.split(/\r?\n/);
    for (const line of lines) {
        const m = line.match(/[0-9a-fA-F]{64}/);
        if (m && /Win11_/i.test(line)) return m[0].toLowerCase();
    }
    // Fallback: first 64-hex string anywhere.
    const any = text.match(/[0-9a-fA-F]{64}/);
    return any ? any[0].toLowerCase() : null;
}

async function findCanonicalIso() {
    let files;
    try { files = await readdir(assetsDir); }
    catch { return null; }
    return files.find(f => /^Win11_.*x64.*\.iso$/.test(f)) ?? null;
}

async function main() {
    const updateSidecar = process.argv.includes('--update');

    const hashSection = await fetchHashSection();
    console.log('\n--- raw hash section text ---');
    console.log(hashSection);
    console.log('--- end raw text ---\n');

    const sha256 = extractSha256(hashSection);
    if (!sha256) {
        console.error('[fail] no SHA-256 found. MS page layout may have changed.');
        console.error('       Inspect the raw text above and adjust the selectors.');
        process.exit(1);
    }

    console.log(`Official MS SHA-256 (${EDITION}, ${LANGUAGE}):`);
    console.log(`  ${sha256}\n`);

    if (!updateSidecar) {
        console.log('To overwrite assets/Win11_*.iso.sha256: pnpm hash:win11 --update');
        return;
    }

    const iso = await findCanonicalIso();
    if (!iso) {
        console.error('[warn] no Win11_*x64*.iso in assets/ — sidecar not written.');
        console.error('       Run pnpm restore first.');
        process.exit(2);
    }
    const sidecarPath = join(assetsDir, `${iso}.sha256`);
    await writeFile(sidecarPath, `${sha256}  ${iso}\n`, 'ascii');
    console.log(`[ok ] wrote ${sidecarPath}`);
    console.log('     git diff --stat to confirm, then commit if the new hash is what you expect.');
}

main().catch(err => {
    console.error('[fail] uncaught:', err);
    process.exit(1);
});
