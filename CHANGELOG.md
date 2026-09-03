# Changelog

## 2026-09-03

### docs: say where the status line is displayed, and where it is not

The README note read "Terminal and IDE only", which users of the VS Code extension took
to mean the CO2 would appear in the extension's chat panel. That panel has no status line
at all: the hooks run underneath it (so `/carbon-report` has the sessions) but there is
no place to display the live figure. The note now says the status line shows only when
`claude` runs in a terminal, integrated IDE terminal included, and tells panel users to
open one. Prompted by a GitHub issue where a user shared the panel screenshot.
### fix: Windows installer survives a stale PATH, a broken Store source and TLS inspection

A real install on a Windows machine behind a TLS-inspecting proxy needed three
manual steps before it went through. None of them was a bug in the plugin, but each
one was a place where the installer could have helped and did not.

- `install.ps1` now merges the registry `PATH` (Machine + User) into its own before
  looking for `jq` and `sqlite3`. A `winget install` followed by a rerun in the same
  terminal works; "open a new terminal" is gone from the message and the README.
  The bash it hands over to inherits the merged value.
- Every `winget install` hint, in `install.ps1`, `scripts/portable-lib.sh`, the
  `install.sh` fallback copy and the README, pins `--source winget`. Without it,
  winget also queries the Microsoft Store source and, when that one fails its
  certificate check, aborts with exit code 94 instead of falling back.
- When the clone fails on Windows with `unable to get local issuer certificate` and
  git is not already on `schannel`, `install.sh` explains the cause and prints the
  one-line fix (`git config --global http.sslBackend schannel`). Verification stays
  on; only the trust store changes.

`tests/run-install-ps1-tests.ps1` gains a section for the merge: it drops one
registry entry from the live `PATH`, checks the merge restores it, and checks a
second merge adds nothing.

## 2026-09-02

### fix: two CLAUDE_* paths missed by the Windows sweep, and the guard that could not see them

A sweep of every path built from a user-set `CLAUDE_*` variable found two the first
pass missed. Both fail silently on Windows, which is the whole reason this class of
bug needs a guard rather than a review.

- `install.sh` built the database path from `CLAUDE_CARBON_DB` without converting it,
  so a user who set it to a native path got the post-update re-pricing skipped: the
  `[ -f ]` test simply found nothing and the step was passed over without a word.
- `generate-report.sh` stamped `last-card-month` under an unconverted
  `CLAUDE_CONFIG_DIR`, while the status line reads that stamp through the converted
  one. The card would write where the status line could not look, so the monthly share
  nudge never cleared.

`tests/run-portability-tests.sh` gains the guard: every `VAR="${CLAUDE_*"` assignment
in a file that runs on a user's machine must go through the conversion.

Writing that guard exposed a worse problem in the suite itself. The list of runtime
files was a space-joined string expanded unquoted, so on a checkout under a directory
whose name contains a space (`~/Claude OS/code/claude-carbon`) it split into filenames
that do not exist. grep read nothing, and the `bc`, `python3` and `/tmp` guards had
been reporting "ok" while checking zero files. They are now an array expanded quoted,
and two positive controls assert the list is real and that grep can read it, because a
guard that cannot fail is worse than no guard at all.

## 2026-09-02

### feat: native Windows support (issue #27)

`npx claude-carbon` refused to run on Windows and the plugin assumed a POSIX
machine everywhere else. It now runs on native Windows through the Git Bash that
Claude Code itself spawns for hooks and the status line, falling back to PowerShell
only when Git Bash is absent, which is why the plugin stays bash rather than being
ported: it speaks the shell its host already uses.

Five things were actually broken, all of them silent failures rather than errors:

**Native paths.** Claude Code is a native binary, so the JSON it pipes into the Stop
hook and the status line carries `C:\Users\me\.claude\projects\...\x.jsonl`, and
`${CLAUDE_PLUGIN_ROOT}` expands the same way. Bash reads those backslashes as escape
characters. A new `scripts/portable-lib.sh` converts every path crossing that boundary
through `cygpath`, with a string rewrite as fallback, and `cc_native_path` does the
reverse for the paths written back into `settings.json`, which Claude Code may resolve
with Windows APIs before handing them to Git Bash. The five `SKILL.md` files carry
their own copy of the conversion: they resolve `CLAUDE_*` variables before any library
is reachable.

**Unquoted placeholders in the hook wiring.** `plugin.json` and `hooks.json` passed
`${CLAUDE_PLUGIN_ROOT}/scripts/x.sh` unquoted. In shell form Claude Code hands that
string to `sh -c`, or to Git Bash on Windows, where the separators disappear. Both
manifests now quote the placeholder, as the hooks documentation requires. This also
fixes a plugin root containing a space on macOS and Linux.

**Line endings.** Git for Windows clones with `core.autocrlf=true` by default, which
would have rewritten every script to CRLF and made bash fail on `$'\r'`. A
`.gitattributes` pins `*.sh` and the other parsed files to LF.

**Two dependencies Git for Windows does not ship.** `bc` was used for three float
comparisons and is now `cc_num_ge`, one awk call; `python3` generated the monthly bar
chart and served the pages for the PNG export, and is now node, already required for
Playwright on that path. `jq` and `sqlite3` are the whole remaining Windows
prerequisite list. The node rewrite of the bar chart was verified by generating all
four report pages from a real 226-session database on `main` and on this branch: the
HTML is byte-identical.

**Symlinked slash commands.** Git Bash silently degrades `ln -s` to a copy without
Developer Mode. `configure-settings.sh` now copies on purpose and refreshes the copy
on every update, so `/carbon-update` still reaches the commands. A file the user wrote
themselves is left alone.

Two smaller wins came out of it: the local PNG export server binds `127.0.0.1` where
`python3 -m http.server` defaulted to `0.0.0.0` and briefly published the pages to the
network, and the macOS Keychain lookup is now guarded on the platform instead of on a
`security` binary that could be something else entirely.

- `install.ps1`: PowerShell bootstrap that locates Git Bash (skipping the
  `System32\bash.exe` WSL launcher), checks `jq` and `sqlite3` through Git Bash's own
  PATH, normalises the downloaded installer's line endings, and hands over to
  `install.sh`.
- `bin/claude-carbon.js`: `npx claude-carbon` finds `bash.exe` instead of refusing,
  honouring `CLAUDE_CODE_GIT_BASH_PATH` first.
- `tests/run-portability-tests.sh`: 32 assertions covering the path conversion with
  the platform forced, `cc_num_ge` cross-checked against `bc` itself where `bc`
  exists, the drift between `install.sh`'s inline fallback and the real library, the
  absence of `bc` / `python3` / hardcoded `/tmp`, the LF pinning, the quoted
  placeholders, and the syntax of every script and every `SKILL.md` bash block.
- `tests/run-windows-e2e.sh`: the assertions no other machine can make, skipped with
  exit 0 off Windows. A real `cygpath` round-trip on a file whose directory contains a
  space; the Stop hook fed a native `transcript_path` and asserted to land a row with
  the right token breakdown, project and branch; the status line fed a native
  `current_dir`; the hook manifests spawned the way Claude Code spawns them, with the
  placeholder substituted into the command string and the string handed to bash from a
  native plugin root; `settings.json` asserted free of backslashes and openable;
  slash-command copies asserted to refresh while a user-written command survives.
- `tests/run-install-ps1-tests.ps1`: `install.ps1` parses, finds Git Bash, refuses the
  `System32\bash.exe` WSL launcher, honours `CLAUDE_CODE_GIT_BASH_PATH` and falls
  through when it points nowhere, normalises a CRLF download, and propagates the
  installer's exit code. Run against a stub served over loopback, so nothing is cloned.
- `configure-settings.sh` hook dedupe: under Git Bash, command substitution drops the
  carriage return from a single-line capture but keeps the interior ones, so reading
  several hook commands back out of `jq` yields a bare CR on every line but the last.
  Our own hook then failed to match itself whenever another tool's hook sat after it in
  the same event, and every install or update appended a second copy. Found by the
  Windows runner, and only because the foreign-hook fixture happened to order them that
  way: with ours last, the accidental case, everything looked idempotent.
- CI gains a `windows-latest` job running the whole suite under Git Bash, which is the
  only place the `cygpath` branch is reachable, plus a `portability` job on Ubuntu that
  also exercises the e2e suite's skip path.
- README gains a Windows section: the three install paths, and the specifics worth
  knowing (forward slashes in `settings.json`, copied commands, no sandboxing).

## 2026-08-24

### fix: totals stay in kilograms until 10 t, projections stay in tonnes

The card hero read "1.0 t of estimated CO2" for a total of 1016.5 kg. The tonne tier started at 1 t, so the first real milestone a heavy user reaches is also the point where the number shrinks to a single significant digit and stops reading as a quantity. `format_co2` now switches to tonnes at 10 t; the same total renders as "1016.5 kg". This is one shared function, so the card, the badge, `/carbon-report` and `/carbon-pr` all move together.

The yearly projection deliberately does **not** follow that rule and keeps its own unit. It is an extrapolation from a daily average, and "1414 - 1686 kgCO2/yr" claims four digits of precision the method does not have; tonnes with one decimal state the same range at the resolution actually supported. Below 0.1 t the tonne tier would collapse to "0.0 - 0.1", so light users fall back to whole kilograms. Both bounds always share a unit, picked on the high end, so a range can never straddle a tier boundary.

`{{PROJECTION_UNIT}}` is a new slot in `report-summary.html` and `report-summary-en.html`, since the unit was hardcoded next to the value.

- `tests/run-badge-tests.sh`: the tonne-tier fixture moves from 1.234 t to 12.34 t, a case pins that 1.234 t still renders as kilograms, and `format_co2` gains boundary assertions on both sides of 10 t (17 assertions).

## 2026-08-24

### docs: recompute.sh understated what it does to mixed-model rows

`recompute.sh` warned that re-pricing collapses mixed-model sessions to the row's dominant model, "~6% high on subagent sessions", and said nothing at all about CO2. Both halves were wrong. Measured while applying the cache-write TTL fix to a real database: over 226 rows, `--with-cost` moved cost from $7,491 to $10,787 (+44%) and CO2 from 194.3 to 225.2 kg (+16%). A session that fans work out to Haiku subagents and carries Fable as its dominant model gets every one of those tokens re-derived at Fable's rate.

That matters because the header presented the CO2-only mode as "safe and idempotent", which invites running it as routine hygiene. It is not: the original insert is model-accurate per subagent and recompute cannot recover that. The note now carries the measured figures and says to prefer a targeted `UPDATE` when a single line item moved, which is how the TTL correction was applied.

### fix: the status line showed the current context size, not the session total

Next to a cumulative session cost, the CO2 figure was computed from `context_window.total_input_tokens`, a snapshot of the context currently loaded. The two numbers sat on different time bases. Caught on a 36-hour multi-agent session displaying `$1775.30 · 17g CO₂` while its stored row held 26.33 kg, a factor of about 1500. Compaction made it worse rather than caused it: each compaction shrinks the window, so the number fell back while the cost kept climbing.

The status line now reads the session's own row from `carbon.db`, written by the `Stop` hook at the end of every turn, so it reports the same cumulative figure as `/carbon-report` (cache reads and subagents included) at most one turn late. The context-window estimate remains as a fallback for the first turn of a session, when no row exists yet, and for a missing database. Excluded rows are never read; the fallback correctly yields 0 for a non-Anthropic model.

The earlier limitation note said this needed Anthropic to expose the token breakdown in the status hook. It does not: the hook already passes `session_id`, and the breakdown is in our own database.

- Four assertions added to `tests/run-install-tests.sh` covering the DB path, the unknown-session fallback, the excluded row, and a missing `session_id` (31 total).
- The data-flow diagram is redrawn and, more to the point, it is now generated. The status-line branch is fed by `carbon.db`, the `context_window` arrow is dashed and labelled as the fallback, and the footnote asking Anthropic for a token breakdown in the status hook is gone.
- `docs/data-flow.excalidraw` is the versioned source and `docs/render-diagram.mjs` renders it (`npm run diagram`, or `npm run diagram:png` to also rasterize through headless Chrome). The README now points at `docs/data-flow.svg`. Previously the diagram existed only as a PNG with no source, which is how it drifted away from the code it documents and stayed wrong through a release. Node only, no dependency added, and the renderer lives in `docs/` so it stays out of the paths `check-versions.sh` and `release.sh` watch.

### fix: cache writes are priced per TTL tier instead of always at the 5-minute rate

`prices.json` carried a single `cache_write_multiplier` of 1.25, the 5-minute rate, and `METHODOLOGY.md` asserted that 1.25 was correct because the 5-minute tier is "Claude Code's default". The transcripts say otherwise: over 24,978 assistant requests, 174,465,500 cache-write tokens landed in `ephemeral_1h` and 0 in `ephemeral_5m`. Claude Code writes at the 1-hour tier, billed 2x input, so every stored `cost_usd` understated that line item by a factor 1.6 (+12.5% on the total for that sample, $5,216 -> $5,870 at Opus list price).

Rather than swap one wrong constant for another, the tier is now read from the data. `usage.cache_creation.ephemeral_1h_input_tokens` is aggregated per session and stored in a new `cache_creation_1h_tokens` column, so a session mixing both tiers prices correctly and a future change of client default needs no code change. `prices.json` gains `cache_write_multiplier_1h` (2.0) next to the existing 1.25.

CO2 is untouched. A cache write is a full prefill whichever TTL it carries; the tier buys retention, not compute. Only `cost_usd` moves.

- New column `cache_creation_1h_tokens`, migrated idempotently by `setup.sh`, `backfill.sh`, `persist-session.sh` and `recompute.sh`. The 1-hour subset is clamped to the cache-write total everywhere, so a malformed transcript can never produce a negative 5-minute remainder.
- Rows captured before the split carry 0 and stay priced at the 5-minute tier. `backfill.sh` gains a repair pass that refills the column from any transcript still inside the 30-day window (same pattern as the `git_branch` repair) and prints a reminder to run `recompute.sh --with-cost` afterwards.
- Golden vectors: the 12 existing vectors keep their exact expected values, since an absent `cache_creation_1h_tokens` reproduces the previous formula. Four vectors added for the 1-hour path, the mixed-tier split, and the clamp.

## 2026-08-22

- fix: the statusline's "install drift" check no longer fires on documentation-only edits. It compared `data/factors.json` and `data/prices.json` byte for byte against the newest plugin cache copy, so changing a `_`-prefixed comment key (17d396a rewrote `_cache_read_factor`, value unchanged) lit the segment on two-install machines. The byte `cmp` stays as the fast path; only when it differs does a `jq` pass strip every `_`-prefixed key at any depth and compare the remaining values. Value changes (top-level or nested) still flag. Single-install machines are unaffected, the check still self-skips there. Covered by five new cases in `tests/run-install-tests.sh`.

## 2026-08-21

- docs: the cache_read_factor section now says what the term actually is. The formula applies a fraction of an uncached input token, so it is a PREFILL residual; earlier versions justified it as the decode-phase KV re-read residual, which is a different object, bilinear in (context x generated tokens) and currently absorbed in the output factor. Consequence stated: long-context agentic use is underestimated. Adds the Irminsul hit/miss measurement (arXiv:2605.05696, Table 1: 14/34/37% on GQA/MHA/MLA at 4096 prefix tokens), explains why 0.14 is not adopted, and widens the published range from 0.05-0.15 to 0.05-0.20 because two of the three measured architectures sit above the old ceiling. The factor value itself is unchanged at 0.08, so all 12 golden vectors are untouched.

## 2026-08-20

### fix: marketplace plugin failed to load on current Claude Code

Recent Claude Code auto-loads a plugin's `hooks/hooks.json`; our manifest still referenced it explicitly, and the duplicate made the whole plugin fail to load ("Duplicate hooks file detected") while the auto-loaded hooks kept running from the cached version. Marketplace installs were silently stuck: skills unavailable, updates refusing to resolve, and the stale cached Stop hook overwriting rows written by newer code (that is how `git_branch` kept getting wiped during the v1.4.0 dogfood). The manifest entry is removed; `hooks/hooks.json` stays, auto-loaded.

### feat: /carbon-pr, the dev footprint of a branch posted on its PR

The number reviewers rarely see is what the PR cost to develop. The Stop hook (and backfill) now store each session's git branch in a new `git_branch` column (read from the transcript's `gitBranch` envelope field, last non-empty value; idempotent migration like the previous columns), and backfill gains a repair pass that fills the branch on already-captured rows while their transcript survives. New `scripts/generate-pr-report.sh` + `carbon-pr` skill: sums the current branch's sessions (project + branch, excluded rows out), renders the same comment contract as the CI action (figures, one equivalence, collapsed per-model detail, Estimated / turn off footer, no em-dash), and upserts one sticky comment on the branch's PR through the developer's own `gh` auth. Opt-in by nature: nothing is posted unless the developer runs it. Covered by `tests/run-pr-tests.sh` (branch capture through the real hook, legacy DB migration, branch-only attribution, guards).

### feat: /carbon-badge, a shields.io badge of your measured footprint

New `carbon-badge` skill and `scripts/generate-badge.sh`: prints a ready-to-paste markdown snippet (plus the raw URL) for a static shields.io badge with the all-time total, clickable back to this repo. Same aggregate as the report's Totals line (stored `co2_grams`, excluded rows out), never re-derived from token columns. `format_co2` moved from `generate-report.sh` into a shared `scripts/format-lib.sh` and gained a tonne tier: users above 1,000 kg now see "1.2 t" on cards and the Totals line where "1234.0 kg" appeared before. Covered by `tests/run-badge-tests.sh` (unit tiers, shields escaping, FR decimal comma, exclusion, missing DB).

### chore: CI-run GitHub Action parked on feat/carbon-ci-action

A composite action measuring `anthropics/claude-code-action` runs was built and tested (sticky PR comment, never-fail contract, golden-vector parity), then pulled from this release: nobody has real agentic CI runs to measure yet, this repo included, and an unused README promise ages badly. The complete implementation lives on the `feat/carbon-ci-action` branch, ready to rebase when real demand shows up.

### chore: release.sh checks npm auth before writing anything

`--npm` publishes at the very end, after the bump is committed and the tag pushed, so an expired npm session left a half-done release; and re-running the whole script double-bumps, which is exactly how the orphan v1.2.0 tag was born today. The script now fails on `npm whoami` up front when `--npm` is passed (skipped in `--dry-run`, which never publishes), and a publish failure late in the run says in so many words to rerun only `npm publish`, never the script.

### feat: cards and the Totals line name their car factor

With three factor sets in circulation, a shared PNG no longer says which one produced its "car equivalent": two readers comparing cards could be comparing 142 against 200 gCO2/km without seeing it. The card now prints a short factor caption under the figure ("142 g/km, ADEME 2025", "200 g/km, world avg", "393 g/mile, EPA US"; a new `tag` field on the car rows of `data/factors.json`, kept short because the full source string overflowed the metric column), and the `Totals since` line prints the full source after the distance, so the social draft that quotes it names the factor too. No number changes anywhere.

## 2026-08-18

### feat: equivalences follow the user's locale

The report compared a US-grid CO2 figure against French factors: an ADEME car, a TGV meaningless outside France, and a French beef average. A car, a kWh and a kilo of beef each differ by a factor of 2 or more between countries, so three sets now ship. A French locale keeps ADEME and SNCF, and so does an undetected one: the French set is the tool's original default, and a hook or CI environment that strips `LANG` should reproduce the previous behavior, not silently switch factor sets. A US locale gets published EPA factors, in miles rather than km since that is both what EPA publishes and what a US reader measures a drive in: 393 gCO2e/mile, 12.4 gCO2 per smartphone charge (EPA's marginal grid rate), and 6400 gCO2e per 150 g steak (Putman et al. 2023's cradle-to-grave 42.7 kgCO2e/kg). Everyone else, non-France francophones included, gets world averages: 200 gCO2/km by car (GFEI's 167 g/km rated global new-vehicle figure plus the ~20% EU real-world gap from OBFCM data, landing between the EU and US real-world anchors), 8.7 gCO2e per charge (EPA's 0.019 kWh at Ember's 458 gCO2e/kWh world grid intensity for 2025) and 14900 gCO2e per 150 g steak (Poore & Nemecek's 99.48 kgCO2e/kg global mean for beef herds, which carries land-use change). The Gemini prompt equivalence is unchanged everywhere. Full derivations and scope caveats in METHODOLOGY.md.

Detection reads `CLAUDE_CARBON_LOCALE`, then `LC_ALL`/`LC_MESSAGES`/`LANG` (skipping `C`/`POSIX` sentinels), then macOS `AppleLocale`, since hooks and GUI-launched shells often carry no `LANG` at all. The twelve factors live in `data/factors.json` under `equivalences`, read by both `/carbon-report` and the card generator through a shared detection lib, so they sit inside the marketplace-cache drift check and the CI runtime-change guard (the golden vectors stay scoped to the emission factors, which did not move). On the PNG cards the FR card always carries the ADEME factor while the EN card follows the locale down to the unit, and the `Totals since` line quotes the set of the exported card. Contributed by Kévin Dunglas (@dunglas).

## 2026-08-12

### feat: add beef steak equivalence

The all-time report gains a fourth equivalence: a 150 g beef steak at 4200 gCO2e (ADEME Impact CO2 beef average, 28.0 kgCO2e/kg from Agribalyse 3.2, times the portion). A food reference reads differently than transport ones, and a typical usage total lands well under one steak, so the line prints one decimal. Report only: the card stays single-metric by design. Contributed by Kévin Dunglas (@dunglas).

## 2026-08-03

### fix: a hook already present under a different spelling was added twice

The wiring compared hook commands as raw strings, so the same script reached `settings.json` twice whenever the two spellings differed. That is not hypothetical: the README's manual block writes `~/code/claude-carbon/scripts/persist-session.sh` while the installer writes the expanded absolute path, and Claude Code also accepts escaped spaces (`~/Claude\ OS/…`). Anyone who wired it by hand and later ran the installer ended up persisting every session twice and running the rescan twice. Commands are now compared on what they resolve to (tilde expanded, escaped spaces unescaped, directory resolved with `pwd -P`), while the entry already in the file is left spelled exactly as the user wrote it. A third-party hook whose directory does not exist is compared literally, as before.

Found by the new install tests rather than by a user, which is the point of them.

### test: the install and update wiring now has a suite

`tests/run-install-tests.sh`, 22 assertions covering cold start, an install predating a hook, a foreign status line and third-party hooks that must survive untouched, repeated runs, equivalent path spellings, the marketplace-cache guard, the repair `update.sh` performs on a local clone, and a corrupt `settings.json` that must be left alone rather than truncated. Each case runs under its own throwaway `CLAUDE_CONFIG_DIR` and nothing touches the network. Removing the spelling fix makes three of them fail, so they are not decorative.

The SessionStart bug fixed earlier today would have been caught by the first case.

### ci: shellcheck on every shell script

2421 lines of bash had no linter. Warnings and errors now gate the build, style notes stay advisory. The pass fixed a `cd` without a guard, a trap that unquoted its temp paths and would have skipped cleanup when the server had already exited, two `local x="$(…)"` masking return values, and an unquoted command substitution in the release script. Two tilde matches are deliberate and carry a justified `shellcheck disable`.

### feat: the update notice names the version

`⬆ /carbon-update` became `⬆ 1.1.3 /carbon-update`, so a patch and a minor can be told apart before deciding to interrupt what you were doing. The three fields are read in a single `jq` call rather than three, since the status line runs on every turn. A flag file written by an older version, without the field, falls back to the bare command. `update.sh` now prints the CHANGELOG URL after updating.

### chore: release script and a CI guard on the version manifests

The update notice is keyed on the version in `.claude-plugin/plugin.json`, so shipping to `main` without bumping reaches nobody: today's SessionStart fix sat behind that exact gap. Two additions make the bump mechanical rather than remembered.

`scripts/release.sh patch|minor|major|X.Y.Z` refuses to run off main, on a dirty tree or out of sync with the remote, checks the three manifests already agree, bumps them together (plus the lockfile), re-reads them to confirm the write landed, commits, tags, pushes, and opens the GitHub release as a draft pre-filled with the CHANGELOG lines added since the last tag. It also reports whether any runtime file actually changed, so a docs-only release that would nag users for nothing is visible before it goes out. `--dry-run` prints every step and writes nothing; npm publishing stays opt-in behind `--npm` since the tarball only carries `bin/`.

Exercised for real against a throwaway local origin, not just in `--dry-run`: the bump lands on all three manifests, the commit and both pushes go through, and a failing `gh release create` no longer aborts silently under `set -e` after the tag is already pushed. It now says what is already published, that nothing is inconsistent, and prints the command plus the kept notes file to finish by hand.

`scripts/check-versions.sh` runs in CI. It fails when the three manifests disagree, which always means one of npm, the marketplace or the notice is lying. It warns, without failing, when files under `scripts/`, `hooks/`, `skills/`, `data/`, `install.sh` or `bin/` changed since the last tag while the version did not: batching commits into one release is normal, silently forgetting for six weeks is not.

### fix: SessionStart hook never wired by install.sh

`install.sh` wrote only `statusLine` and the `Stop` hook, so every curl/npx install has been missing `SessionStart` → `safety-rescan.sh` since the beginning (`git log -S SessionStart -- install.sh` is empty). Two things were silently off for those users: the throttled safety rescan that catches sessions the Stop hook missed (crash, kill, hook disabled), and the update notifier, since `check-update.sh` is launched from `safety-rescan.sh` and the status line only ever reads the flag it writes. They were never told a new version existed. Marketplace installs were unaffected, `hooks/hooks.json` declares the hook.

The settings and slash-command wiring moves out of `install.sh` into `scripts/configure-settings.sh`, called by both `install.sh` and `update.sh`, so an install predating a hook is repaired on the next `/carbon-update` instead of staying half-wired. `update.sh` previously delegated to `setup.sh` under a comment claiming it refreshed settings; `setup.sh` only ever touched the database. The merge stays additive and idempotent (third-party `SessionStart` hooks and a foreign `statusLine` are preserved), and now writes through tmp + mv: the old truncating redirect would have destroyed the user's `settings.json` if `jq` had failed mid-write.

The README's manual-install block had the same hole, so anyone wiring it by hand reproduced the bug: it now shows both hooks and says what each one does, and points at `configure-settings.sh` for people who would rather not hand-edit JSON (the manual path also never installed the `/carbon-*` commands).

## 2026-08-02

### chore: gitignore .claude/settings.local.json

Per-machine Claude Code permission file, was sitting untracked. Last gap flagged by a repo hygiene pass against the GitHub community checklist (health score 100%, everything else already in place).

### docs: MCP servers lever in Reduce your footprint

New subsection after Compact earlier: disconnecting unused MCP servers cuts the tool schemas re-sent with every request. Deliberately unquantified (no row in the Combined impact table): the overhead is mostly cache reads, whose energy factor is the methodology's widest band, so any percentage would be false precision. Mechanism plus `claude mcp list` / `claude mcp remove` only.

### docs: Related projects section in the README

Four entries before Further reading, tools rather than papers: EcoLogits, CodeCarbon, ImpactIA (link only, its CC-BY-NC-SA license keeps its data out of the factors), green-claude. ImpactIA already cites claude-carbon as an integration target, so the link closes the cross-reference.

## 2026-08-01

### feat: install-sync check in the statusline (stale plugin cache detection)

Incident behind it: on a machine running both a git clone (statusline, manual scripts) and a marketplace install (the Stop/SessionStart hooks that write carbon.db), the marketplace cache stayed at v1.0.0 while the clone moved to v1.1.1. Six weeks of sessions were persisted with pre-v6 factors, and Fable sessions fell back to the sonnet family (no fable support in 1.0.0): CO2 overstated 2.8x overall, fable costs understated 2.25x. Every check (golden vectors, fact-checks, update notice) ran green because they all looked at the current copy; auto-update is opt-in for third-party marketplaces, so the cache never moved. Fixed operationally with `claude plugin update` + `recompute.sh`.

- statusline.sh now compares its own `data/factors.json` and `data/prices.json` byte-for-byte against the newest plugin cache copy (`~/.claude/plugins/cache/*/claude-carbon/<latest>/`) and appends `≠ install drift` when they differ. Local-only (two `cmp` calls per render, no state file, no network), self-skips when the statusline runs from that cache copy (single-install machines never see it), ignores superseded version dirs, opt-out via `CLAUDE_CARBON_NO_UPDATE_NOTIFIER`-style env `CLAUDE_CARBON_NO_DRIFT_CHECK`.
- Chosen over recomputing recent db rows against current factors: subagent tokens are folded into the session row with per-model CO2 (persist-session.sh), so a math check would false-positive on cross-model subagent sessions (e.g. Haiku routing), while an install comparison has no false positives and fires the day the copies diverge.
- check-update.sh: corrected the comment claiming marketplace users get native auto-update (it is opt-in for third-party marketplaces); the notice itself still targets git-clone installs only.

### feat: monthly share nudge and post draft in /carbon-card

- statusline.sh shows `📊 /carbon-card` to the first 3 distinct sessions of each month (tunable via `CLAUDE_CARBON_CARD_NUDGE_SESSIONS`), then goes quiet until next month, so it never nags: generate-report.sh stamps the month in `last-card-month` (clears the nudge immediately) and prints a `Totals since ...` summary line. Opt-out via `CLAUDE_CARBON_NO_CARD_NUDGE`. No auto-posting anywhere: the action stays human.
- /carbon-card now offers a paste-ready social post draft built only from the printed totals, factual register enforced (numbers and equivalences, no self-congratulation); attribution stays in the card footer, not in the draft.
- skills: fixed REPO_DIR resolution when `statusLine.command` contains a shell-escaped path (e.g. `~/Claude\ OS/...`): tilde and escaped spaces are now expanded, so /carbon-card and /carbon-update run the install actually wired into the statusline instead of falling back to `~/code/claude-carbon` or the plugin cache.

### docs: CITATION.cff and a Citing section in the README

License stays plain MIT. Citation is encouraged, not required: CITATION.cff enables GitHub's "Cite this repository" button, the README documents the short form, and the report cards keep carrying the repo + tokenclimate.com attribution in their footer (the highest-reach citation channel).

### docs: correct source framing and refresh report equivalences

An external reader's critique prompted a full audit of the public docs against primary sources. None of these changes touch the emission factors or any computed CO2 number.

- Jegham et al. is an arXiv preprint, never published in a peer-reviewed venue, and it estimates energy from public API performance data (latency, throughput) via Monte Carlo over inferred hardware configurations rather than measuring it. README and METHODOLOGY called it "a peer-reviewed study" that "measures" energy / "measured AWS telemetry". Reworded throughout, and the published critique of the paper's absolute values (Memento Humani, Nov 2025) is now cited in Limitations.
- Corroboration claims toned down: the EcoLogits band spans ~2.5x, so landing inside it is a consistency check, not "strong corroboration"; the three routes share assumptions (price proxy, parameter-count models) and do not corroborate the input factor at all (0 to ~390 Wh/Mtok across routes); Couch's figures are Opus-anchored while compared against Sonnet factors.
- The "1.3-51.8%" KV-cache amplification figure comes from Solovyeva & Castor, not From Prompts to Power; attribution fixed inline and From Prompts to Power dropped from the source list. The "single biggest lever" limitation now quantifies the swing (~0.65x-1.5x across the 0-0.20 bound) and notes output tokens dominate at the default.
- Report equivalences refreshed with current primary sources: car 120 -> 142 gCO2e/km (ADEME Impact CO2, 2025 model, lifecycle), Google search at 0.2 g (a 2009 blog figure misattributed to the 2023 environmental report) replaced by the median Gemini prompt at 0.03 g (Google, Aug 2025), TGV 2.4 -> 3.5 g/km (SNCF open data 2024, full scope), email 19 g (ADEME 2011, withdrawn; current reference ~2.5 g) removed. Applied in `/carbon-report`, `generate-report.sh` and METHODOLOGY; the old values are documented under the new table.
- README reduction percentages (-60/-70/-80) are now labeled indicative estimates, with the RTK self-reported figure and the Haiku 0.5x dependency called out.
- Consolidated uncertainty statement in Limitations: reports keep a single point estimate by design; the plausible range (~0.7x-3x) and its likely direction are documented in one place instead of ranges in the UI.
- Follow-up: the "-80% on exploration" Haiku routing claim was inconsistent with the tool's own factors (Haiku = 0.5x Sonnet = 0.25x Opus per token implies -50% vs Sonnet subagents, -75% vs Opus). The table now derives the gain from the factors and states both baselines, and warns that a Haiku-dominated total rides entirely on the widest band in the tool.

## 2026-07-22

### fix: skill invocations ignored `CLAUDE_CONFIG_DIR` / `CLAUDE_CARBON_DIR` (#15, #16)

The path sweep that taught the installer and scripts to honour `CLAUDE_CONFIG_DIR` and `CLAUDE_CARBON_DIR` never touched `skills/`, so the bash embedded in three SKILL.md files still pointed at the default `~/.claude` and `~/code/claude-carbon`. On a second environment (`CLAUDE_CONFIG_DIR=~/.claude-work`) or a custom install dir, `/carbon-card`, `/carbon-report` and `/carbon-update` read or wrote the wrong location. They now resolve paths the same way the scripts do: `carbon-report` reads the DB from `${CLAUDE_CARBON_DB:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claude-carbon/carbon.db}` and points its setup hint at `${CLAUDE_CARBON_DIR:-$HOME/code/claude-carbon}`; `carbon-update` reads `settings.json` from `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`; `carbon-card` locates the install from the status-line command (falling back to `CLAUDE_PLUGIN_ROOT`, then `CLAUDE_CARBON_DIR`) instead of the hardcoded default. Default behaviour is unchanged when neither variable is set.

## 2026-07-21

### feat: honour `CLAUDE_CONFIG_DIR` for second Claude environments (#15)

Claude Code can run out of an alternate config dir (`CLAUDE_CONFIG_DIR=~/.claude-work claude`), but every path in claude-carbon was hardcoded to `~/.claude`, so a second environment could not track itself. All state now resolves against `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`: the settings merge and `/carbon-*` command symlinks (install.sh), the database dir (setup.sh, safety-rescan.sh), the transcript scan and inserts (backfill.sh, persist-session.sh), the re-price and report reads (recompute.sh, generate-report.sh), and the usage cache, credentials lookup and update-notice flag (statusline.sh, check-update.sh, update.sh). Install into the alternate dir by putting the var on the `bash` side of the pipe. Because the hooks and status line inherit `CLAUDE_CONFIG_DIR` from the environment that launched `claude`, each environment writes its own DB. Default behaviour is unchanged when the var is unset. As a side effect `generate-report.sh` now also honours `CLAUDE_CARBON_DB` like the other scripts (previously it ignored it).

### fix: `CLAUDE_CARBON_DIR` install example passed the var to `curl`, not `bash` (#16)

The documented custom-directory one-liner set `CLAUDE_CARBON_DIR=... curl ... | bash`, which scopes the variable to `curl`; the piped `bash` never saw it and installed to the default location. Moved the assignment to the `bash` side of the pipe.

## 2026-07-20

### feat: `--until` for closed reporting periods

`generate-report.sh` could only report from a start date up to today, so a card for a finished period (a semester, a quarter) was impossible: the headline number always swept in the current month. `--until` takes an exclusive upper bound, and everything that implicitly meant "now" is re-anchored on it.

- SQL window gets an upper bound (`started_at < UNTIL`).
- The annual projection and the trailing-30-day trend measure to the period end instead of today. Without this, a January-June card extrapolated its run rate from July sessions.
- The label under the headline states the bound. "823 sessions depuis janvier" otherwise reads as "up to now" while the number says otherwise.
- The filename carries the window (`claude-carbon-summary-fr-2026-01-01_2026-06-30.png`), so two runs over different periods no longer overwrite each other.
- The generation date in the top-right corner is dropped on a closed period: it says nothing useful and contradicts the stated window.

Default behaviour is unchanged when `--until` is absent.

## 2026-07-19

### feat: weekly traffic snapshot (stats/)

GitHub's traffic API only keeps a 14-day rolling window, so `scripts/traffic-snapshot.sh` merges per-day views/clones into `stats/traffic.json` (latest fetch wins on overlapping days) and appends dated referrer/path snapshots as JSONL. Runs Mondays via `.github/workflows/traffic.yml` (workflow_dispatch too); needs a `TRAFFIC_TOKEN` fine-grained PAT secret with repository Administration read, because the traffic endpoints reject the default Actions token. Seeded with the current window: unique cloners ≈ real installs (install.sh and npx both end in `git clone`; updates are `git pull` and don't count).

### feat: `--segment` mode for embedding in other status lines

`statusline.sh --segment` prints only the cost + CO2 pair (`$0.68 · 35g CO₂`) and exits before the progress bar, the 5h-quota lookup (so never any network call) and the git branch call. Built for [ccstatusline](https://github.com/sirmalloc/ccstatusline) custom command widgets, which pass the same status JSON on stdin; documented in the README ("Using with ccstatusline"). Full mode output is byte-identical to before.

### docs: mid-2026 evidence sweep in METHODOLOGY.md

Literature check (July 2026): Jegham et al. still at v6, EcoLogits now a published paper but still parametric for Claude, no official Anthropic disclosure. Two documentation additions, no factor changes, golden vectors untouched:

- Cross-validation: added Couch (Jan 2026) as a third independent route (Epoch AI per-query estimate scaled by API price ratios, ~1,950 Wh/Mtok output vs ~2,880 here, within ~1.5x).
- Limitations: replaced the multi-region bullet with a fleet-mix limitation covering the tri-hardware fleet (AWS Trainium/GPU, Google TPU 1+ GW in 2026, Nvidia) and the ~300 MW gas-powered Memphis Colossus 1 lease (SpaceX S-1, May 2026). Weighted CIF effect ~+5-10%, flagged as a watch item.

### docs: demo GIF, social preview template, npm + CI badges

- `docs/demo.gif` at the top of the README: a scripted session replayed through the real `scripts/statusline.sh` (driver: `docs/demo/fake-session.sh`, recorder: `docs/demo/demo.tape` via vhs). Every frame is the actual renderer output; only the JSON snapshots are fabricated.
- `templates/social-preview.html`: 1280x640 GitHub social preview in the report-card visual style, rendered to `exports/social-preview.png` (local, exports/ is gitignored) for manual upload in Settings > General.
- README badges: npm version and CI workflow status next to the existing three.
- `.gitignore`: `promo/` (local marketing drafts stay out of the repo).

### docs: complete the GitHub community standards checklist

Added the five files the Community Standards page flagged as missing:

- `CODE_OF_CONDUCT.md`: Contributor Covenant 2.1, contact email for enforcement.
- `CONTRIBUTING.md`: project layout, `bash tests/run-vectors.sh`, the golden-vector rule for any `data/factors.json` / `data/prices.json` change, PR conventions, release manifest sync.
- `SECURITY.md`: private reporting (GitHub advisory or email), explicit scope (OAuth token, transcripts, installer/hooks execution, no unexpected network calls).
- `.github/ISSUE_TEMPLATE/`: bug report and feature request as YAML forms (version, install method, runtime environment fields), plus a contact link routing security reports away from public issues.
- `.github/PULL_REQUEST_TEMPLATE.md`: checklist mirroring CONTRIBUTING, with a dedicated section for methodology changes.

### feat: npm wrapper package (`npx claude-carbon`)

Published claude-carbon to npm as a thin wrapper so the package page and the registry-derived links (Socket.dev, ecosyste.ms, libraries.io, unpkg) exist, without changing the git-based distribution:

- `package.json` at the repo root (name `claude-carbon`, version synced with `plugin.json`, `files` limited to `bin/` - npm adds README/LICENSE itself; tarball is 4 files, ~8 kB).
- `bin/claude-carbon.js`: downloads `install.sh` from `main` and runs it through bash, propagating the installer's exit code. Flags: `--dry-run` (download only), `--version`, `--help`. `CLAUDE_CARBON_INSTALL_URL` overrides the source (pin a branch/fork, used by tests). Refuses Windows (the installer needs bash) and requires Node >= 18 (global `fetch`).
- README install section now offers `npx claude-carbon` next to the curl one-liner.
- Verified end-to-end against a local stub server (exit-code propagation included) and with `--dry-run` against the real GitHub URL; `npm pack --dry-run` checked for tarball contents.

Publishing (`npm publish`) is manual for now; a GitHub Action on tag can automate it later. Version bumps must keep `package.json` in sync with `plugin.json`/`marketplace.json`.

## 2026-07-15

### feat: contextual TokenClimate pointers in report and cards (1.1.1)

The OSS now routes "what about my team?" intent to the hosted layer at the moment it appears, without any ambient nagging or data collection:

- `/carbon-report` ends with a single footer line: `Team view (same methodology): tokenclimate.com`.
- The four `/carbon-card` PNG templates carry a small muted credit under the open-source badge (`vue équipe · tokenclimate.com` / `team view · tokenclimate.com`), so shared cards surface the link to viewers.
- Deliberately no status-line promo and no email capture: the update notice stays the only status-line extra, and lead capture remains on tokenclimate.com.
- The README "For teams" section documents both pointers explicitly, so the link in the output is an announced choice, not a surprise.
- Bumped the plugin version to **1.1.1** (`plugin.json` + `marketplace.json`).

## 2026-06-22

### feat: "update available" notice, one-command `/carbon-update`, and auto re-price on update

Existing installs had no way to know a new version shipped, and updating was a manual curl re-run that `git pull --ff-only` would break for anyone who had edited `data/factors.json` (which the README invites). Added a full update flow:

- **Notice**: a backgrounded, once-a-day version check (`scripts/check-update.sh`, run detached from the SessionStart hook) compares the local vs remote `plugin.json` version and writes a cached flag. The status line reads that flag locally (no network on the hot path) and shows a discreet `⬆ /carbon-update` when behind, with a 7-day staleness gate. Opt out via `CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1`. Marketplace-cache installs are skipped (they use Claude Code's native auto-update).
- **Update**: a `/carbon-update` slash command (and a hardened `install.sh`) run `scripts/update.sh`, a dirty-safe `git pull` that stashes only the two user-editable data files and, on conflict, preserves the user's version to `*.local.bak`.
- **Recompute on update**: after a pull, history is re-priced with the new factors automatically. `recompute.sh` now defaults to **CO2-only** (idempotent, no mixed-model cost drift); cost re-pricing is opt-in via `--with-cost`. Added a 5s SQLite busy-timeout (`sqlite3 -cmd ".timeout 5000"`) so a concurrent Stop-hook write doesn't fail the recompute, and the recompute now refuses non-numeric config values (they are interpolated into SQL).
- Bumped the plugin version to **1.1.0** (`plugin.json` + `marketplace.json`) so marketplace users are offered the update.

### Refine emission factors and pricing to the best available data to date (multi-source, cross-validated)

Triangulated the per-model CO2 factors and Anthropic pricing across independent sources (Jegham et al. v6 empirical AWS measurements, EcoLogits parametric LCA, third-party inference-energy studies, AWS regional grid data), with adversarial verification of the load-bearing numbers.

- CO2 (gCO2e/Mtok, usage-only, AWS region grid 0.287): **Sonnet 39/826** - a 3-point OLS fit to Jegham v6's three measured Claude 3.7 Sonnet energies (0.950 / 2.989 / 5.671 Wh), cross-validated by EcoLogits which brackets the same range. **Opus 78/1652** (2x Sonnet): the current EcoLogits Opus 4.5+ parameter ratio and the Anthropic price ratio both imply ~1.7-2x, replacing the earlier 3x; honest band 2x-5x. **Haiku 20/413** (0.5x). **Fable 156/3304** (2x Opus). Bands and unmeasured-extrapolation caveats are documented in `METHODOLOGY.md`.
- Relabeled the 0.287 kgCO2e/kWh carbon intensity as the AWS region grid (location-based), not a "US average" (the US average is ~380); kept 0.287 as the Jegham-consistent basis.
- Pricing: all USD list prices reconfirmed current (Opus $5/$25, Sonnet $3/$15, Haiku $1/$5, Fable $10/$50; cache write 1.25x 5-min tier, read 0.1x) - no drift. Added `eur_per_usd` (ECB reference rate 2026-06-22, 0.8729) for EUR display, and documented the 2x 1-hour cache-write tier.

These remain order-of-magnitude estimates and will keep being refined as measurements improve. Updated `data/factors.json`, `data/prices.json`, script fallbacks, `METHODOLOGY.md`, `README.md` and the golden vectors. Run `scripts/recompute.sh` to re-price stored rows.

### docs: note terminal/IDE-only compatibility in README

The status line and shell hooks only run in the Claude Code terminal CLI and IDE extensions, not the web (claude.ai/code) or desktop app. Added an explicit note under the install steps so users on the app don't expect CO2 tracking there.

## 2026-06-12

### feat: exclude non-Anthropic models from cost/CO2 accounting (#7)

Claude Code pointed at a local model (via `ANTHROPIC_BASE_URL`) was silently counted as Sonnet, with Sonnet datacenter factors and Anthropic API pricing. Sessions whose dominant model string does not contain `claude` (including `<synthetic>`) are now stored with raw tokens but `cost_usd = 0`, `co2_grams = 0` and a new `excluded` column set to 1, and filtered out of all reports (`/carbon-report`, `generate-report.sh`). The statusline shows 0g for those models. A user-configurable `exclude_models` pattern list in `data/factors.json` can exclude additional models by name. Schema migration is the usual idempotent `ALTER TABLE`; raw tokens are preserved so excluded rows can be re-priced by `recompute.sh` if local-model factors are ever added.

### feat: Fable 5 model family (pricing + extrapolated emission factors)

`claude-fable-5` / `claude-mythos-5` were falling into the Sonnet fallback of `resolve_family`, under-costing them by 70%. New `fable` family across all scripts (backfill, persist-session, recompute, statusline): pricing $10/$50 per Mtok (current Anthropic list price), emission factors 1000/6000 gCO2e/Mtok extrapolated from Opus by the 2x list-price ratio (no published measurement; same approach as the Opus 3x-Sonnet extrapolation, documented in METHODOLOGY.md).

### fix: LC_ALL=C in carbon-report skill awk calls (#10)

The bash script in `skills/carbon-report/SKILL.md` called awk without `LC_ALL=C`. Under comma-decimal locales (de_DE, fr_FR), awk truncated values at the decimal point (431.7045 → 431) and rendered output with commas. `export LC_ALL=C` at the top of the script covers all seven calls, mirroring the fix already applied to `scripts/*.sh`.

### fix: backfill.sh derives project name from cwd instead of directory name (#11)

`backfill.sh` took the last hyphen-separated token of the transcript directory name, which destroyed real hyphens in project names (`billing-service` → `service`) and merged distinct projects. It now reads the first `cwd` from the transcript JSONL via `jq -n 'first(inputs ...)'` (no SIGPIPE under `set -o pipefail`) and takes its basename, matching `persist-session.sh`. Previously backfilled rows keep their old names; delete and re-run backfill to normalize (noted in README).

## 2026-06-05

### fix: deduplicate tokens, correct pricing, and count cache_read energy

Three correctness fixes to token accounting in `backfill.sh` and `persist-session.sh`, validated against ccusage on the same JSONL:

- **Deduplication.** `aggregate_jsonl` now dedups assistant messages by `(message.id, requestId)` keeping the last occurrence, before summing. Resumed/compacted sessions replay prior messages within a file and streaming writes the same message repeatedly; 55% of assistant lines on observed data are replays, so the previous raw sum over-counted tokens ~3x. The duplication is entirely within-file, so per-file dedup is sufficient.
- **Pricing.** Replaced the hardcoded $15/$75 (retired Opus 4.0/4.1 rate) with current Anthropic list pricing: Opus 4.6+ $5/$25, Sonnet $3/$15, Haiku $1/$5. Cost now also counts cache_write at 1.25x input and cache_read at 0.1x input. On deduplicated data `cost_usd` reconciles to within a few percent of ccusage.
- **Cache read energy.** Cache reads (90%+ of token volume) are no longer excluded from CO2. They now count at `cache_read_factor` (default 0.08) of the input factor, an engineering estimate of the decode-phase KV re-read residual, documented in METHODOLOGY.md and `data/factors.json`. This is not the 0.1x billing ratio (a price, not energy).

Schema gains a `cache_read_tokens` column (idempotent `ALTER TABLE` migration in setup/backfill/persist; new installs get it in `CREATE TABLE`). `CLAUDE_CARBON_DB` env var added to override the DB path for testing. Existing rows keep their old values until a re-backfill; new live sessions use the corrected methodology immediately.

### feat: durable raw-token storage + recompute, surviving the 30-day JSONL purge

Make the DB self-sufficient so derived metrics survive Anthropic's ~30-day transcript purge and any future methodology change, without ever needing the JSONL again.

- **Raw tokens stored, not just derived numbers.** Added `cache_creation_tokens` and `methodology_version` columns. Rows now carry the full breakdown (regular input = `input_tokens - cache_creation_tokens`, cache write, cache read, output), so cost and CO2 become pure functions of stored tokens + config.
- **`recompute.sh`** (new). Re-derives `cost_usd` and `co2_grams` for all `methodology_version >= 2` rows from `data/factors.json` + `data/prices.json`, no JSONL. Run it after any price/factor change. Mixed-model sessions recompute at the dominant model (small approximation; the insert is per-subagent accurate). `CLAUDE_CARBON_FACTORS` / `CLAUDE_CARBON_PRICES` env overrides for testing.
- **`data/prices.json`** (new). Pricing moved out of the scripts into config (Opus $5/$25, Sonnet $3/$15, Haiku $1/$5; cache write 1.25x, cache read 0.1x). A future price change is one edit + `recompute.sh`, not a code change in three scripts.
- **`safety-rescan.sh`** (new) + `SessionStart` hook. Throttled (once/day), backgrounded `backfill.sh` re-run that catches sessions the `Stop` hook missed, while their transcript is still on disk.

Verified end-to-end on a temp DB: backfill stores the raw breakdown; recompute reproduces totals from tokens alone (~$2,667 / 230 kg, matching ccusage); changing the cache_read_factor moves CO2 only; changing a price moves cost only.

## 2026-04-21

### fix: restore reset time display when stdin passes epoch

Claude Code injects `rate_limits.five_hour.resets_at` as a Unix epoch (number), while the fallback API returns ISO-8601 with fractional seconds + tz offset. The parser now branches on numeric vs string input and strips `.fraction`, `Z`, and `+HH:MM` suffixes before `date -j -u -f`. Without this, the stdin path left `END_EPOCH` empty and the `↻HH:MM` suffix silently disappeared.

### refactor: 5h quota via Anthropic OAuth API (drops ccusage heuristic)

The 5h block usage % is now pulled from `https://api.anthropic.com/api/oauth/usage` (same data as `/usage` in Claude Code), with a stdin-first path reading `rate_limits.five_hour.used_percentage` when Claude Code injects it. Removes the ccusage dependency, the learned `token-limit` file, the `CLAUDE_CARBON_TOKEN_LIMIT` env seed, the async refresh lock, and the npx cold-start latency. Accurate on Max 20x without needing to saturate a block first. OAuth token resolved from macOS Keychain, env, or `~/.claude/.credentials.json`. Response cached 60s in `~/.claude/claude-carbon/oauth-usage.json`. The 🔥 burn-rate prefix and `↻HH:MM` reset time are preserved; block start is derived as `resets_at - 5h`.

## 2026-04-19

### fix: stale lock + UTC-to-local conversion for reset time

Two bugs masked the correct 5h block reset time: (1) the async-refresh lock file could survive a crashed/killed ccusage process and block every subsequent refresh indefinitely (6h of stuck data in practice), and (2) macOS `date -j -f` without `-u` parses the UTC timestamp as local time, making `↻11:00` display when the real reset was 13:00 (or 18:00 after the block rolled over). Locks older than 60s are now broken on the next run, and both `startTime`/`endTime` are parsed as UTC then formatted in local via epoch.

### feat: learned token limit file with auto-bump

The 5h quota % is now computed against a persistent ceiling stored in `~/.claude/claude-carbon/token-limit`. The file is seeded from the `CLAUDE_CARBON_TOKEN_LIMIT` env var on first run (or can be written directly), then auto-bumps whenever an observed block exceeds it. Falls back to ccusage's heuristic if neither is set. Fixes the Max 20x case where ccusage's heuristic ceiling is far too low until a block has been saturated, inflating the displayed percentage (68% shown when `/usage` reported 24%). README explains the seeding procedure via `/usage`.

## 2026-04-17

### feat: richer status line (git branch + 5h quota usage)

Status line now shows project, git branch (`⌥ branch`), model, context window %, session cost + CO2, and 5h block quota usage with reset time (`Use X% ↻HH:MM`). A 🔥 prefix appears when usage >= 15% AND burn rate >= 50%/h since block start, with a 15 min grace window to absorb bursty session starts. Quota data fetched via `ccusage` with a 30s file cache and async background refresh to avoid blocking the status line. Strips `(1M context)` / `(200K context)` from model display name. Reordered segments left-to-right: project → model state → cost → quota.

## 2026-04-09

### docs: update README install instructions

Removed plugin marketplace install (not validated by Anthropic). Added Playwright + Chromium install instructions for `/carbon-card`.

### feat: one-line installer (install.sh)

`curl | bash` installer that clones the repo, runs setup, and auto-configures `~/.claude/settings.json` (statusLine + Stop hook). Supports custom install directory via `CLAUDE_CARBON_DIR`. Idempotent: updates existing installs with `git pull`.

### feat: plugin marketplace support

Restructured as official Claude Code plugin. Installable via `/plugin install claude-carbon` or `curl | bash`. Added `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.

### chore: add GitHub badges to README

Stars, license, and release badges for social proof.

## 2026-04-05

### feat: generate-report.sh + report-card.html

PNG card generator for LinkedIn sharing. Queries carbon.db for total CO2, sessions, cost, car km equivalence, top 3 projects, and most used model. Injects into a branded HTML template (violet/orange/cream, Clash Display + Owner Text) and exports retina 2x PNG via Playwright.

## 2026-04-05

### feat: statusline.sh

Reads Claude Code status JSON from stdin. Outputs formatted status line with color dot (green/yellow/red), 10-block progress bar, cost, CO2 in adaptive g/kg units, and project name.

### feat: setup.sh

Init script: checks jq/sqlite3 deps, creates ~/.claude/claude-carbon/carbon.db with sessions schema + index, runs backfill, prints CO2 summary (total + current year), and next-steps guide for settings.json.

### feat: backfill.sh

Parses all historical ~/.claude/projects/_/_.jsonl transcripts. Aggregates tokens per session, estimates cost by model family, calculates CO2 using factors.json, inserts into DB with source='backfill'. Skips non-UUID filenames, subagents/ and vercel-plugin/ dirs, and already-processed sessions.

### feat: persist-session.sh

Stop hook: reads statusline JSON from stdin, calculates CO2, INSERT OR REPLACE into carbon.db with source='live'. Completely silent on all failures (missing DB, missing session_id, jq/sqlite3 errors).

### feat: skills/carbon-report/SKILL.md

/claude-carbon:report skill. Inline bash script queries carbon.db and displays today/year/all-time totals, equivalences (car km, Google searches, TGV km), top 5 sessions by CO2, and per-project breakdown.

### feat: plugin.json + hooks.json

plugin.json declares plugin metadata, statusLine command, and skills directory. hooks.json wires persist-session.sh to the Stop hook.

### docs: README.md + METHODOLOGY.md + LICENSE

README covers install, emission factors, usage, and dependencies. METHODOLOGY documents the Jegham et al. 2025 source, formula, infrastructure parameters (PUE/CIF/WUE), per-model factors, and limitations. LICENSE is MIT 2026.
