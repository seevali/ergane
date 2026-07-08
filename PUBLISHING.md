# Publishing the Ralph Loop Installer to npm

This document is the checklist for manually publishing `@seevali/ergane` to npm after the Ralph Loop Installer chapter is complete. **This step is not automated by the loop.**

## Prerequisites

- Node.js 20+ installed
- npm account with publish permissions (`npm whoami` shows your username)
- 2FA enabled on your npm account (best practice)
- Your npm token stored locally (run `npm login` once if needed)
- Clean git state: `git status` shows no uncommitted changes
- On `main` branch: `git branch` confirms you're on main

## Pre-publish checklist

### 1. Verify all tests pass

```bash
cd installer
npm test
```

**Expected:** All tests pass, no warnings or errors.

### 2. Run the doctor command on a fresh install

Simulates what `npx` users will experience:

```bash
cd /tmp
mkdir -p ralph-test
cd ralph-test
npx @seevali/ergane install --yes
npx @seevali/ergane doctor
```

**Expected:**
- Install completes in < 60 seconds (excluding BMAD download)
- `doctor` exits 0 with a passing checklist
- No error messages or warnings

### 3. Verify pack size budget

```bash
cd /path/to/ergane/installer
npm pack
mkdir -p /tmp/pack-verify
tar xzf seevali-ergane-0.2.0.tgz -C /tmp/pack-verify
du -sh /tmp/pack-verify/package
# Should show < 1 MB
rm -rf /tmp/pack-verify
rm seevali-ergane-0.2.0.tgz
```

**Expected:** Unpacked size < 1 MB (typical: 400–600 KB).

### 4. Verify git state

```bash
git log --oneline -5
git status
```

**Expected:**
- Current commit is the story 4.3 merge (contains finalized `package.json`, `PUBLISHING.md`, all prior story changes)
- No uncommitted changes (`git status` is clean)

## Publish workflow

### Step 1: Log in (one-time setup)

```bash
npm login
```

Follow prompts to enter your npm username, password, and 2FA code. Your credentials are stored in `~/.npmrc`.

### Step 2: Publish

```bash
cd installer
npm publish
```

**Expected output:**
```
npm notice 📦  @seevali/ergane@0.2.0
npm notice === Tarball Contents ===
npm notice [list of files]
npm notice === Tarball Details ===
npm notice name:          @seevali/ergane
npm notice version:       0.2.0
npm notice size:          XXX KB
npm notice unpacked:      XXX KB
npm notice shasum:        [sha]
npm notice integrity:     [integrity hash]
npm notice === Publish Details ===
npm notice Publishing to the default npm registry.
npm notice Publishing @seevali/ergane v0.2.0 from the current working directory
+ @seevali/ergane@0.2.0
```

**If 2FA-protected:** you'll be prompted for a one-time code (OTP) from your authenticator app.

### Step 3: Verify publication

```bash
npm view @seevali/ergane@0.2.0
```

**Expected:** Shows the published version with all metadata (description, author, repository, etc.).

### Step 4: Cold-start test

Test the installed package on a clean machine or in a fresh shell (no local cache):

```bash
# On a clean machine or in a container:
cd /tmp && mkdir ralph-cold-start && cd ralph-cold-start
npx @seevali/ergane@0.2.0 install --help
```

**Expected:**
- Wizard displays help text
- Completes within 3 seconds (cold npx cache, first download ~5 s)
- No errors

## Rollback (if needed)

npm does not support unpublishing versions after 24 hours (npm policy). If you need to withdraw a publish:

### For versions < 24 hours old:

```bash
npm unpublish @seevali/ergane@0.2.0
```

**Note:** Users who installed before unpublish still have it; this only prevents new installs.

### For versions ≥ 24 hours old:

Publish a bugfix version with a deprecation notice instead:

```bash
# In installer/package.json, bump version to 0.2.1
# Publish the corrected version
npm publish
# Then deprecate the old one
npm deprecate @seevali/ergane@0.2.0 "Use 0.2.1 or later."
```

Then update this `PUBLISHING.md` and notify users.

## Appendix: npm metadata reference

The published package includes:

- **name:** `@seevali/ergane` (scoped to @seevali namespace)
- **version:** `0.2.0` (semantic versioning)
- **description:** Interactive wizard to install and manage the Ergane build loop—an agentic workflow for software projects
- **author:** Seevali Rathnayake <seevalihrathnayake@outlook.com>
- **license:** MIT
- **repository:** https://github.com/seevali/ergane (installer subdirectory)
- **bugs:** https://github.com/seevali/ergane/issues
- **homepage:** https://github.com/seevali/ergane#readme

After publish, all metadata is queryable via `npm view @seevali/ergane`.
