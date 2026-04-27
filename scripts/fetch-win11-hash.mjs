// scripts/fetch-win11-hash.mjs
//
// Drives the official Microsoft Windows 11 download page via Playwright
// to (1) extract the authoritative SHA-256 for the multi-edition English
// x64 ISO, and (2) optionally download the ISO from the same session.
// The hash sits behind a JS-rendered "Verify your download" link, and
// the download URL is a one-shot session-bound URL — so static HTML
// scraping (curl + regex) doesn't see either, we run a real browser.
//
// Used when the in-git sidecar (assets/Win11_*.iso.sha256) drifts: Fido
// pulled a newer build than what we recorded, or the local copy got
// corrupted. fetch-assets.ps1's soft-warn message tells the user to
// run this script.
//
// Run:
//   pnpm hash:win11                           # print the hash
//   pnpm hash:win11 -- --update               # overwrite the in-git sidecar
//   pnpm hash:win11 -- --download             # also download the ISO
//   pnpm hash:win11 -- --download --update    # both
//   pnpm hash:win11 -- --debug                # non-headless browser for selector debug
//
// Requires `playwright` (devDependency) — installed by `pnpm i`. Browser
// binaries are pulled by Playwright's own postinstall.

import { chromium } from 'playwright';
import { writeFile, readdir, mkdir, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot  = dirname(__dirname);
const assetsDir = join(repoRoot, 'assets');

const MS_URL    = 'https://www.microsoft.com/software-download/windows11';
const EDITION   = 'Windows 11 (multi-edition ISO for x64 devices)';
const LANGUAGE  = 'English (United States)';
const CANONICAL = 'Win11_25H2_English_x64_v2.iso';

const args = new Set(process.argv.slice(2));
const flags = {
    update:   args.has('--update'),
    download: args.has('--download'),
    debug:    args.has('--debug'),
};

async function drivePage() {
    console.log(`[info] launching Chromium (${flags.debug ? 'visible' : 'headless'})...`);
    const browser = await chromium.launch({ headless: !flags.debug, slowMo: flags.debug ? 250 : 0 });
    const ctx = await browser.newContext({ acceptDownloads: true });
    const page = await ctx.newPage();
    try {
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

        // After #submit-sku the page exposes BOTH:
        //   a) a 64-bit download anchor (24-hour-validity URL)
        //   b) the "Verify your download" link that reveals the hash table

        // 3. Hash extraction (always)
        const verifyLink = page.locator('a:has-text("Verify your download")');
        await verifyLink.waitFor({ timeout: 30_000 });
        await verifyLink.click();
        const hashContainer = page.locator('.product-verification-container');
        await hashContainer.waitFor({ timeout: 30_000 });
        const hashSection = (await hashContainer.innerText()).trim();

        let downloadInfo = null;
        if (flags.download) {
            // 4. Capture the 64-bit download.
            //    The button's text is something like "64-bit Download" — selector
            //    might shift; try the obvious label first, fall back to any anchor
            //    pointing at MS's CDN.
            const candidates = [
                page.locator('a:has-text("64-bit Download")').first(),
                page.locator('a[href*="software.download.prss.microsoft.com"]').first(),
                page.locator('a[href$=".iso"]').first(),
            ];
            let dlAnchor = null;
            for (const c of candidates) {
                try {
                    await c.waitFor({ timeout: 10_000 });
                    dlAnchor = c;
                    break;
                } catch { /* try next */ }
            }
            if (!dlAnchor) {
                throw new Error('Could not locate the 64-bit Download anchor. Re-run with --debug to inspect the page; the selector may have changed.');
            }
            const href = await dlAnchor.getAttribute('href');
            console.log(`[info] download URL captured: ${href ? href.slice(0, 80) + '...' : '(missing)'}`);

            await mkdir(assetsDir, { recursive: true });
            const target = join(assetsDir, CANONICAL);

            // Use Playwright's download event — saveAs() streams bytes through
            // its own pipe, so we don't need to re-auth or replay headers.
            const downloadPromise = page.waitForEvent('download', { timeout: 60_000 });
            await dlAnchor.click();
            const download = await downloadPromise;

            console.log(`[info] saving to ${target} (this is the slow part — ~5 GB)`);
            const progress = startProgress(target);
            try {
                await download.saveAs(target);
            } finally { stopProgress(progress); }

            const finalSize = (await stat(target)).size;
            console.log(`[ok ] downloaded ${(finalSize / 1024 / 1024 / 1024).toFixed(2)} GB`);
            downloadInfo = { path: target, bytes: finalSize, url: href };
        }

        return { hashSection, downloadInfo };
    } finally {
        await ctx.close();
        await browser.close();
    }
}

// Polled progress display: prints bytes-on-disk every 2 s while the download is
// in flight. Playwright's saveAs() is a black box — no per-byte callback — so
// peeking at the destination file is the simplest way to show movement.
function startProgress(targetPath) {
    let lastBytes = 0;
    const start = Date.now();
    const id = setInterval(async () => {
        try {
            const s = await stat(targetPath);
            const mb = (s.size / 1024 / 1024).toFixed(0);
            const elapsed = ((Date.now() - start) / 1000).toFixed(0);
            const rate = ((s.size - lastBytes) / 1024 / 1024 / 2).toFixed(1);
            process.stdout.write(`\r       ${mb} MB downloaded (${rate} MB/s, ${elapsed}s elapsed)   `);
            lastBytes = s.size;
        } catch { /* file may not exist yet */ }
    }, 2000);
    return id;
}
function stopProgress(id) {
    clearInterval(id);
    process.stdout.write('\n');
}

function extractSha256(text) {
    const lines = text.split(/\r?\n/);
    for (const line of lines) {
        const m = line.match(/[0-9a-fA-F]{64}/);
        if (m && /Win11_/i.test(line)) return m[0].toLowerCase();
    }
    const any = text.match(/[0-9a-fA-F]{64}/);
    return any ? any[0].toLowerCase() : null;
}

async function findCanonicalIso() {
    let files;
    try { files = await readdir(assetsDir); } catch { return null; }
    return files.find(f => /^Win11_.*x64.*\.iso$/.test(f)) ?? null;
}

async function main() {
    const { hashSection, downloadInfo } = await drivePage();

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

    if (downloadInfo) {
        // Verify the download against the hash we just got from the same page.
        const { createHash } = await import('node:crypto');
        const { createReadStream } = await import('node:fs');
        console.log(`[info] verifying ${downloadInfo.path} against scraped hash...`);
        const h = createHash('sha256');
        await new Promise((resolve, reject) => {
            createReadStream(downloadInfo.path)
                .on('data', (c) => h.update(c))
                .on('end', resolve)
                .on('error', reject);
        });
        const dlHash = h.digest('hex').toLowerCase();
        if (dlHash === sha256) {
            console.log(`[ok ] downloaded ISO matches scraped MS hash`);
        } else {
            console.log(`[fail] downloaded ISO does NOT match scraped hash:`);
            console.log(`       expected ${sha256}`);
            console.log(`       actual   ${dlHash}`);
            console.log(`       (rare — same-session corruption. Try again.)`);
            process.exit(3);
        }
    }

    if (flags.update) {
        const iso = downloadInfo ? CANONICAL : await findCanonicalIso();
        if (!iso) {
            console.error('[warn] no Win11_*x64*.iso in assets/ — sidecar not written.');
            console.error('       Add --download or run pnpm restore first.');
            process.exit(2);
        }
        const sidecarPath = join(assetsDir, `${iso}.sha256`);
        await writeFile(sidecarPath, `${sha256}  ${iso}\n`, 'ascii');
        console.log(`[ok ] wrote ${sidecarPath}`);
        console.log('     git diff --stat to confirm, then commit if the new hash is what you expect.');
    } else {
        console.log('To overwrite assets/Win11_*.iso.sha256: pnpm hash:win11 -- --update');
        if (!downloadInfo) {
            console.log('To also download the ISO: pnpm hash:win11 -- --download');
        }
    }
}

main().catch(err => {
    console.error('[fail] uncaught:', err);
    process.exit(1);
});
