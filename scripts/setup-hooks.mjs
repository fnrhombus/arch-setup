// setup-hooks.mjs — point git at the in-repo .githooks directory.
//
// Runs from npm/pnpm `prepare` (which fires after every install, including
// fresh clones). Cross-platform: just shells out to `git config`.
// No-ops gracefully if we're not inside a git checkout (e.g. install from
// a tarball, CI without .git history) so it never blocks an install.

import { execSync } from 'node:child_process';
import { existsSync } from 'node:fs';

if (!existsSync('.git')) {
    // Not a git checkout — nothing to wire up.
    process.exit(0);
}

try {
    execSync('git config core.hooksPath .githooks', { stdio: 'pipe' });
    console.log('git hooks: core.hooksPath -> .githooks (pre-commit validate-hypr-binds active)');
} catch (err) {
    // Don't fail the whole install if git config errors for some odd reason.
    console.warn('git hooks: failed to set core.hooksPath:', err.message);
}
