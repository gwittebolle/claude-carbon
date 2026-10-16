# Changelog

## 2026-10-16

### feat: /carbon-pr counts an agent for the branch it worked on

A session counted whole for the branch it ended on: agents that a session on `main` sent
to build a PR in a worktree were counted on `main`, and the PR showed nothing. A new
`SubagentStop` hook (`agent-stop.sh`) reads, as each agent ends, the branch it worked on:
that of the worktree it ran in, when that is a worktree of its own (isolated and workflow
agents), or that of the worktree its tool calls named in at least half of those that give
a place (a command, a file path), when it ran in the session's folder. Paths are matched
whole (`x-1013` is not `x-1013-facultatif`), absolute, under `~/`, `../` or `./`, with
Windows spellings; descriptions, prompts and the text an edit writes are not read. Left
out: branches Claude Code names itself (`worktree-agent-*`, `worktree-wf_*`), detached
worktrees, the repository's main folder and the session's own, forks, Claude Code's own
agents.

The agent's usage, per model and computed as its session's pass computes that file, goes
to a new `agent_usage` table, with the repository and the worktree's folder. Claude Code
writes transcripts asynchronously: when the agent's final message is not in its
transcript yet, the hook reads it again every 0.2 s, for 1 s at most. `/carbon-pr` takes
the agent out of its session's branch and adds it to its own when the session's row holds
all its agents (`agents_collected = 2`), was written after the agent ended (in a later
second) and is not a frozen v1 row, and says how many sessions recorded elsewhere it
includes. An agent that worked in another repository than its session's is not recorded,
and one recorded before its repository was moved stays with its session. A session's own row does not change, the branches still add up to the sessions,
and `recompute.sh` re-derives the agents' share with them. Without any agent row for the
repository, or on a database that cannot be migrated, the comment is unchanged.

Once agents of the repository are on record, `--pr` run from another folder than the
branch's (the main one, often) also counts the sessions of the repository's main folder,
of the worktree the branch is checked out in and of the worktrees its agents worked in,
even removed since: it summed the agents without the PR's own sessions. A branch checked out nowhere whose name sessions
of other folders also carry is refused, rather than posted without them. The branch is
read in full (`refs/heads/...`): a tag of the same name made it `heads/<name>`, and the
report found no session.

Only agents that end with this version installed are attributed. The hook needs Claude
Code 2.1.69 or later and records nothing with an older one. Claude Code's own agents are
left out: in a session run without `--agent` their type is empty (the hook's matcher skips
them from 2.1.275, the script before that); with `--agent` their transcript is not one the
session's row reads. The hook runs synchronously: on a Mac, about 0.1 to 0.3 s for most
agents, up to about 1 to 2 s for one whose transcript passes 100 MB. A database kept busy
for more than about 10 s loses the record, and the agent counts with its session.

### fix: a fresh install with jq 1.6 writes its settings

On a machine with no `settings.json` yet, the installer built one with jq, naming a
variable `$end`. jq 1.6 (Ubuntu 20.04 and 22.04, Debian 11) reads `end` as a keyword and
stopped there: the file was left empty, with no status line and no hooks. The variable is
renamed, and the file is written through a temporary copy, so a jq that fails never leaves
an empty one. A test now rejects any jq variable named after a jq 1.6 keyword.

### perf: agents' transcripts are read again only when they change

The Stop hook, the daily rescan and the status line read every transcript of a session
each time: on a session with a hundred agents, several seconds after every answer, though
an agent's transcript stops changing once it is done. Each agent's totals are now kept in
`usage-cache/`, beside the database's default folder, one file per session, keyed by the
transcript's path, size, modification and change times and inode (of the file a symlink
points to), all read before the files are. A transcript is read again when any of them
changes; the main transcript is always read, and an agent with a line that did not parse
is never kept. A cache that cannot be read is ignored and rewritten, a stat that does not
answer as expected means no cache for that pass, and the daily rescan removes a session's
file 45 days after it was last written. `CLAUDE_CARBON_NO_USAGE_CACHE=1` turns it off.
The figures do not change.

### fix: sessions with hundreds of agents are recorded on Windows

A session's usage was read by one jq process given every transcript's path. Windows stops
a command line at 32,767 characters: past about 150 to 190 agents, jq did not start, and
the Stop hook and the rescan left the session as it was, without a word. Each transcript
is now reduced on its own and the results summed, with jq run in the session's folder on
relative paths, in batches of at most 16 KB of arguments. The figures do not change: the
same lines, byte for byte, on every session tested.

A transcript cut mid-line with no final newline also lost the first line of the transcript
read after it; only the cut line is lost now.

### fix: the status line reads transcripts only for a session without a row

The status line falls back to reading a session's transcripts when the database has
nothing for it yet, on its first turn. It also did so for a session whose row it set
aside (an excluded model, or no CO2 yet), at every refresh. It now shows that row's CO2,
0 for an excluded session, and reads the transcripts only without a row, at most once
every 10 seconds and again as soon as the transcript grows.

### fix: sessions rewritten by an older Stop hook get their workflow agents back

The rescan compared each session that ran workflows once, then set a marker. A session
opened before the update keeps running the previous version's Stop hook until it is
closed, and that hook rewrote the row without its workflow agents after the pass; no
rescan looked at it again. Each row now records whether the version that wrote it read
every agent transcript (a new `agents_collected` column). An older hook resets it when it
rewrites the row, and the first daily rescan after the session closes re-aggregates it.
The marker file is no longer used.

Also in the rescan:

- a session is counted as repaired once its row is written; a write that fails leaves the
  row for the next rescan;
- a row is rewritten only if no Stop hook recorded it while the rescan read its
  transcripts, and if it holds no more tokens than they now give: a turn recorded in the
  meantime, even by an older hook, is never overwritten, and lands on the next rescan;
- a rewritten row ends when its transcripts were last written, agents included. A row
  written from all its transcripts is no longer parsed again for the cache-write or
  context repairs, nor a row without tokens, nor one whose agent last wrote a line
  without usage;
- an agent transcript that cannot be read, or that disappears during the rescan, is left
  out instead of failing the whole session;
- on Windows, the lines jq returns no longer keep a CR: the end of a session the rescan
  added was stored with one, which kept the rescan from rewriting that row, and the last
  of the `exclude_models` patterns never matched. Rows stored that way are refreshed.

`/carbon-pr --pr` takes a PR number only, and refuses a PR opened from a fork: its branch
is not one of this repository's, and a local branch of the same name (often `main`) would
have been summed in its place.

### fix: the agents a workflow starts are counted

Claude Code writes the transcript of an agent a workflow starts to
`<session>/subagents/workflows/wf_*/agent-*.jsonl`, one level below the subagents the
hooks read. Those agents were left out of the session: on sessions that ran workflows,
the CO2 and cost recorded were 10% to over five times too low. The Stop hook, the
backfill and the status line's fallback now read them (the workflow's `journal.jsonl`,
which carries no usage, is not read).

A session already recorded without them is re-aggregated by a daily rescan, while its
transcripts are still on disk (Claude Code keeps them about 30 days); older ones stay as
they were. Rows of the legacy methodology (v1), a frozen series, are never touched.
Reported by a user.

### fix: /carbon-pr --pr reports that PR's own branch

`--pr <number>` chose where to post, but the sessions summed were still those of the
branch the command ran on: run from main, it would have posted main's footprint on the PR
as its own. It now reads the PR's head branch through `gh` and sums that branch's
sessions, wherever it runs; a PR it cannot read stops the command. When a branch has no
session, it says nothing was posted and why work done by agents in a worktree, driven
from a session on another branch, is not on it.

## 2026-10-15

### fix: /carbon-card no longer stalls Chrome on Windows

The card waited for its web fonts through Chrome's virtual time, which on a Windows
machine stalled the browser's network service: even a blank page never came back, and
the card fell back to a page in the browser. Each font file the card's stylesheets name is
now preloaded instead, which Chrome waits for before its screenshot, the same fonts in a
few seconds. Offline, the card is drawn in the system's fonts rather than not at all.

### fix: /carbon-card waits 60 seconds for the browser's first start

A Chrome started headless with a fresh profile took 19 to over 45 seconds on a Windows CI
runner, so the card fell back to a page in the browser. The browser now has 60 seconds
before it is stopped; only the first card of a run pays for the profile, the next ones
reuse it. When the real-browser test fails, it now prints what the browser did.

### fix: the detail's bars label the hovered part, percentages to one decimal

Hovering a part of a detail bar lights it up and shows, under the bar, its kind and its
figures on that bar ("Cache relu · 23,9 Md tokens · 98,4 %", "Sortie · 239 kWh ·
68,6 kgCO₂ · 27,4 %"), the way the stripes show theirs, in place of the system tooltip.
A label too long for a narrow pane is set smaller rather than cut, on the stripes too,
which now share the same label.
The detail's percentages carry one decimal. Each bar names its own ids and classes, so
the two bars and the stripes never answer each other's hover. The colour keys in front of
the kinds carry a text alternative, without which the desktop app left them out.

### feat: the /carbon-panel pane shows the detail by kind of token

A new "Détail" switch under the gear of "Mon usage" (off until turned on) splits the
period between uncached input, cache writes, cache reads and output. Two coloured bars
give each kind's share of the tokens and of the CO2, then one line per kind its tokens,
energy (Wh, kWh) and CO2 with their shares, and a total, in the author's palette
(Amethyst, sand, Pierre, Tangerine). Under it, a link to METHODOLOGY.md for the assumptions. The CO2 of each session is the
stored one, split with the weights the factors already apply; a session stored with older
factors (before July 2026), whose CO2 no longer matches its tokens, is left out, and the
block says over how many sessions it splits; the energy is the one the factors start from,
found back by dividing that CO2 by their grid intensity, 287 gCO2/kWh. `sessions-history.tsv` gains four columns, the tokens by kind,
written by the hooks from this version on; until the next answer rewrites it, the
block says the detail is on its way. No factor changes.

### fix: the card's token count includes cache reads

The summary card's token tile added input and output only, so it left out cache reads,
over 90% of a Claude Code session's tokens, while the CO2 and the API-price cost on the
same card included them. It now counts every token Claude processed, shows billions past a
billion ("25.3B", "25,3 Md"), reads "tokens processed" / "tokens traités", and gives the
share of cache reads in a grey line under it. The CO2 and the cost do not change. The first
card made after the update says so once, for anyone comparing with an earlier card.

In the README, the emission-factor table gains the cache-read column (0.08 of the input
factor, as already applied), with plain-language headers and a line on where a session's
CO2 comes from, and the example card is redrawn.

### feat: /carbon-card makes its PNGs with the browser already installed

The PNG export needed Playwright and its Chromium, which few people have: everyone else
got the card as a page in their browser and a screenshot to take. When Playwright is
missing, the card is now drawn by a Google Chrome, Microsoft Edge, Chromium or Brave
already on the machine (Windows always has Edge), run headless in a throwaway profile
through the same local server, at the same 2160x2160. A file that is not a PNG of that
size counts as no card, and the page opens in the browser as before.
A browser that has drawn nothing after 25 seconds is stopped and not tried again.
`CLAUDE_CARBON_BROWSER` names a browser, by path or by command, or `none` to skip the lookup.

## 2026-10-14

### feat: the /carbon-panel pane names a newer release

A marketplace install had no way to learn of a new version: the status line's
`⬆ /carbon-update` hint only covers a git clone, and the desktop app shows no status line.
Its SessionStart hook now asks GitHub once a day for the release tags (read-only, nothing
fetched into Claude Code's plugin cache) and writes `plugin-update-check.json`. When a newer
release exists, the pane's foot says which one and the command to ask Claude to run,
`claude plugin update claude-carbon@claude-carbon`, then restart. The pane compares it with
its own version, so the line goes away once updated, and ignores a check older than a week.
`CLAUDE_CARBON_NO_UPDATE_NOTIFIER=1` turns it off, as it does the status line's hint.

### fix: the pane's first link says what it offers

The first link of the foot reads "En savoir plus sur claude-carbon" ("Learn more about
claude-carbon") and still opens the repository's home.

### fix: the pane's first link opens the repository's home

"Comment c'est calculé" linked to METHODOLOGY.md; the line now reads "claude-carbon sur
GitHub" and opens the repository, whose README leads to the methodology.

### fix: the pane's author link opens the author's LinkedIn profile

"Développé par : Gaëtan Wittebolle" now links to linkedin.com/in/gwittebolle instead of
the personal site.

### fix: the pane's foot names TokenClimate as the business version

The foot's two credit lines read "Développé par : Gaëtan Wittebolle" and "Découvrez la
version entreprise : TokenClimate" (in English "Built by:" and "Discover the business
version:").

### fix: the /carbon-panel pane reads right on a first install

Seen on a fresh install. The (i) of the API-price and car tiles revealed their note on
hover, which the desktop app did not do: each (i) is now a button, a click shows the note
under the tiles and a second hides it. Before three periods with sessions in them, the
stripes drew one grey block; they now say they are coming ("Vos bandes de couleur
apparaissent après 3 jours d'usage (1 pour l'instant)"). The car tile reads "< 1 km"
instead of "≈ 0 km". The note under a new molecule says it plainly: "Couleur provisoire :
elle s'ajustera à vos habitudes après 10 sessions". The foot's last line reads like the
one above it: "En équipe avec TokenClimate".

### fix: Haiku's emission factors halve, to 0.25x Sonnet

Haiku was estimated at 0.5x Sonnet (20 / 413 gCO2e per million tokens), a middle
between readings that disagree. It is now 0.25x (10 / 207), set between two public
bounds: EcoLogits 0.11.2 puts Haiku 4.5 at about 0.07x Sonnet 5.5 per output token, and
the output speed Artificial Analysis measures on Anthropic's API (Haiku 5.5 237 tokens/s,
Sonnet 5.5 135) bounds the ratio at about 0.57x from above. Their geometric middle,
0.21, is rounded up, since Haiku 5.5 comes close to Sonnet 5.5 in capability and may be
a larger model than the one EcoLogits describes. The list-price ratio (0.05x) is not
used. METHODOLOGY.md gives the derivation. Sessions on Haiku, often its subagents, count
half the CO2 they did; the update re-prices stored history as usual. The golden vectors'
Haiku expectations move accordingly, costs unchanged.

### fix: the /carbon-panel pane's foot no longer credits the stripes

The README carries the credit to Ed Hawkins' warming stripes; the pane's foot keeps the
methodology, the author and TokenClimate.

### docs: the README cites ADEME first for the 2 t per-person target

The `/carbon-report` budget line's source in the README now names ADEME's Nos Gestes
Climat, which gives 2 t as a world average from the IPCC 1.5 °C scenarios, before
Carbone 4's _Faire sa part ?_. METHODOLOGY.md already cited both.

### feat: the molecule has a colour from the first answer

Before 10 past sessions the `/carbon-panel` molecule stayed grey for want of a median.
It now compares the session with a starting reference of 0.5 kgCO₂ until then, and
with the person's own median from the 10th session on (`colourMedian` in
`hooks/mod/lib/sessions.ts`); subagents' small molecules follow the same reference. The
pane says so under the session while the reference applies. The ratio "× your median"
still shows only once the median is the person's own.

### docs: the README's desktop illustration and the social preview show the pane

`docs/desktop-pane.png` now shows the Claude desktop app with the `/carbon-panel` pane
open (the molecule, the session, the period's tiles and stripes, the card button), and
`docs/social-preview.png` (1280x640, uploaded by hand in the repository's settings)
sets the name, the eight molecules and the stripes beside that window. Both are drawn
from the launch film's app scene, in English. The animated preview built from the
status-line demo and its two scripts are gone. The README's first paragraph names the pane,
its list puts `/carbon-panel` first, the desktop illustration sits in "Option 1" and the
status-line demo in "Option 2", and its mod section is now "The mod: /carbon-panel and the CO2 of each answer". The
banner at its top is now `docs/banner.png`, the preview's layout on a light
ground: the name, the eight molecules and a terminal with its status line beside the pane; the walking
molecules move to the "Open source" section, next to the stripes' credit. The preview
and the banner show the pane alone, in a card.

### docs: Ed Hawkins' stripes credit at the end of the README and on the pane's last line

The credit left the top of the README for its "Open source" section, and in the pane it
is now the last line of the foot, as plain text with no link.

### feat: a Mac without jq gets the official one at install, and CI runs on macOS

macOS ships `jq` from 15 (Sequoia) on; on an older Mac with no Homebrew the installer
stopped at "jq is not installed", with no simple way out for someone who only uses the
desktop app. `install.sh` now fetches the official jq 1.8.1 binary for the Mac's
processor, checks it against the SHA-256 the jq project publishes for that release, and
puts it in `~/.claude/claude-carbon/bin/`. `scripts/portable-lib.sh` and the slash
commands put that folder on `PATH` only when no `jq` is found, so a `jq` of the system
keeps precedence. A download whose checksum does not match installs nothing.
`tests/run-jq-fetch-tests.sh` covers the refusal, the `PATH` order and, on macOS, the
real download. CI gains a macOS job that runs every bash suite under the system's own
`/bin/bash` 3.2, the version a Mac user's hooks run with.

### fix: the /carbon-panel pane after /clear, on a phone, and around a clock change

After `/clear` or `/resume` the pane kept the conversation before as the running one:
it left that conversation out of the period and counted the new one twice. It now
reads the new conversation's id and the history again, the one before counted as a
past session. On a phone (Remote Control), which has no text field, a custom range no
longer leaves the pane blank: its two dates show as text. A custom range drawn by week
or by month counts from its first day, not from the Monday or the 1st before it (its
first stripe is then partial), and "7 days" or "30 days" go back by calendar days, so
the week after a change of clock no longer gets an extra stripe. The pane reads the
history again after each answer, so other sessions running at the same time show
without reopening it. The test of the export counts its temp files with a glob, as
shellcheck asks.

## 2026-10-13

### fix: backfill names a session's project after its last folder, as the live hook does

A session opened in a parent folder that moves into a sub-project was named
after the sub-project by the Stop hook, which reads the cwd of the latest turn,
and after the parent folder by `backfill.sh`, which read the transcript's first
cwd. A row rebuilt by backfill could therefore move from `my-app` to the parent
folder. Backfill now takes the transcript's last cwd, through the same path
conversion as the hook on Windows, so both paths give the same project. A
transcript whose last line was cut by a crash keeps the cwd of the lines before
it. The README's `/carbon-pr` note now speaks of the session's last folder.
`tests/run-per-model-tests.sh` covers a session that changes folder mid-way,
with and without a truncated last line.

### fix: the status line writes gCO₂ and kgCO₂, as the mod and the reports do

The status line printed `65g CO₂` and `84.2kg CO₂`; it now prints `65gCO₂` and
`84.2kgCO₂`, the unit the mod, the pane and the cards use. The README's
examples, the demo GIF and the social preview follow. The demo now records from a
throwaway repository on `main`, so it never shows the branch it was made from.

### fix: the status line's first turn shows the session's CO2, not a context estimate

On a session's first turn the status line draws before the Stop hook has written
the session's row, and nothing redraws it after. It fell back to the context
window, all input at the full input factor, cache reads included: 6 gCO₂ for an
answer the database and the mod both put at 4.3 gCO₂. With no row yet, the status
line now runs the Stop hook's own computation (`cc_session_usage`) on the
transcript, short at that point, subagents included; the context-window estimate
stays as the last fallback, with no database or no transcript.

### feat: the pane shows where this session sits on the colour scale

Under the molecule in the desktop app's pane, a small scale of the eight colours,
bluest to reddest, with a marker under this session's colour (`scaleSvg` in
`hooks/mod/lib/mascot.ts`); no marker while the molecule is grey, before a median
exists. Its alt text reads the place out ("6e position sur 8").

### docs: the README's molecules pull the pane's faces

The banner's eight molecules walk as before and now wear the faces the
`/carbon-panel` pane gives their weight: the blue ones smile, the middle ones
blink and glance aside, the red ones sweat. A new drawing in the pane's section,
`docs/molecule-moods.svg`, shows its eight moods with a caption each. Both come
from `scripts/render-mascot.mjs`, which now draws from the mod's own faces and
moods (`moleculeCss` and `moleculeHop`, exported by `hooks/mod/lib/mascot.ts`,
take a scope so several molecules keep their own mood in one drawing), and which
can also write the moods as a GIF (`--gif out.gif`, ImageMagick) for places an SVG
does not play.

## 2026-10-12

### feat: /carbon-panel opens a pane with a CO2 molecule and the warming stripes of your sessions (1.11.0)

The mod registers `/carbon-panel`, which opens a pane, or closes it when it is open.
The command is also a skill (`skills/carbon-panel`, linked by the installers), so
the desktop app lists it; the mod catches both spellings before the skill's text
reaches the model, and that text only answers where the mod does not run. At
the top, a pixel CO2 molecule (`hooks/mod/lib/mascot.ts`) coloured by this
session's CO2 against the median of past sessions, in eight classes by powers of
two from dark blue to dark red, grey until 10 past sessions are recorded. It hops
one pixel up and down while a main-loop turn runs, one step every 460 ms for
the bluest down to 124 ms for the reddest: a small 13 x 4 cell molecule blitted
into a `Raster` in the terminal, a CSS animation inside an `Svg` in the desktop
app, still under reduced motion. It pulls faces as it goes, over a body that never
changes (`FACES`, `MOODS`): it looks around before the first answer, blinks and
glances aside while at work, smiles through a light session and sweats through a
heavy one, smiles or startles for a moment after each answer, winks and looks up
at rest, and falls asleep with a z after five minutes without a turn. In the
desktop app each face is a layer of the Svg shown in turn by CSS; in the terminal
the picture follows the clock, a blit at each hop and each change of face. In the desktop app, below it, warming
stripes of past sessions, the running one included with its live total, covering
exactly the period picked: 7 or 30 days by day, 12 months by week (from Monday),
everything or a custom range of two typed dates by day, week or month after its
length (`windowOf` in `hooks/mod/lib/sessions.ts`), empty periods included as
gaps. They are coloured against the median of the periods shown with sessions in
them (uncoloured under three), the one still filling left out of it; at most 180
stripes in the desktop app's side pane, the most recent.
The range is a row of buttons, the custom dates two `Input` fields read at Enter
(`parseDay`: day first or ISO, a date that does not exist refused); the choice is
kept in `$.store` for the next session. The stripe under the pointer lights up and
its label (date, total, sessions) shows under the stripes at once, drawn in the
Svg and revealed by CSS `:hover`, since the app's own tooltip is slow and placed
far off; the Svg's viewBox matches its drawn width so the label keeps its shape.
The tab is titled "claude-carbon", and a few short lines held at the pane's foot
link to the methodology, to Ed Hawkins' warming stripes (showyourstripes.info), to
the author's site and to TokenClimate (`?ref=carbon-panel`). The pane opens without the keyboard, so typing
and Escape stay with the prompt. The period's figures (CO2, change, sessions,
API-price value, car) are tiles under the range buttons; then the blocks the person chooses under the gear beside "My usage", kept in
`$.store`: the change
against the same length of time before, the API-price value (worded so it holds
whoever pays: a Pro or Max subscription covers some or all of it), the car
equivalence
of the reports (`hooks/mod/lib/equiv.ts`), and the split by project (off until
turned on). A tile that needs a word of explanation (the API-price value, the
car's factor and source) shows an (i), and the pointer on the tile reveals the
note under the tiles: a hover group of the surface (`hover.scope`, a Box drawn
`display: "none"`), no hook and no redraw. The session block gives its
answers, subagents and model, its context window's fill (`$.session.usage()`)
and API-price value, and in the desktop app a small molecule per subagent
(`subagentsSvg`, eight then "+N"), coloured by the CO2 of its own requests, and
walking, breathing and blinking like the big one. Typed in a terminal, `/carbon-panel`
opens no pane (in fullscreen rendering it would dock as a whole column for four
lines): it turns on and off the session in the band above the prompt. Sent to a
terminal session from the desktop app or a phone (Remote Control, origin `bridge`),
it opens the side pane there (`panelSite` in `hooks/mod/lib/sessions.ts`). The band
(`AbovePrompt`, drawn over whatever it already holds, never over a survey) holds the
small molecule with its lines beside it and a dot per subagent in its colour.
The period, the stripes, the card and the links are the desktop app's. The history file now also carries each session's model. A "Get my 2026 card" button (the card covers the
calendar year so far, whatever range the pane shows) puts `/carbon-card` in
an empty prompt (`$.prompt.fill`) and never sends it; a draft in progress is left
alone.

The history comes from `sessions-history.tsv`, which the Stop hook now writes next
to `carbon.db` after each answer, and the SessionStart hook at the start of each
session, detached (`cc_export_sessions` in `scripts/portable-lib.sh`):
sessions not excluded and with CO2, oldest first, as id, start in epoch seconds,
grams, methodology version, project and API-price cost. Legacy (v1) rows are in
it as stored and count like the others, as in `/carbon-report`. The rows come from a `sqlite3 -readonly` query written
to a temp file and renamed into place. The mod resolves the file as the hooks
resolve the database (`CLAUDE_CARBON_DB`, `CLAUDE_CONFIG_DIR`, then `HOME` or
`USERPROFILE`) and still writes no database, starts no process and makes no
network call; `hooks/mod/carbon-pane.test.tsx` checks it. Without the file (the
plugin installed alone) the pane shows the molecule and says where the history
comes from. Someone welcomed by an earlier version sees a one-time toast naming
`/carbon-panel`. The README banner is now drawn from the mod's frames and palette by
`scripts/render-mascot.mjs`. Tests: `tests/run-export-tests.sh` (in CI on Linux
and Windows), kit tests for the pane, and checks of the frames, the half-block
cells, the history file, the stripes by week and month and the pane's texts in
`tests/run-mod-tests.mjs`.

### docs: a pixel CO2 molecule as the README mascot

The README opens on a row of eight pixel CO2 molecules (O=C=O, the carbon in
the middle with two eyes), coloured from dark blue to dark red like warming
stripes. They hop, two frames each, from one step every 460 ms for the bluest
to one every 124 ms for the reddest; with reduced motion they stand still. The
image is `docs/mascot-stripes.svg`: plain pixel paths and a CSS animation, no
script, with a grey outline so the darkest colours stay visible on GitHub's
dark theme. A line under it credits Ed Hawkins' warming stripes.

### feat: the mod's pinned entry gives the session's CO2 and API-price cost (1.10.0)

The entry the mod pins under the prompt now reads `Cette session : 3,6 gCO₂ ·
0,12 $` in French and `This session: 3.6 gCO₂ · $0.12` in English, with
no-break spaces before the French colon and around the units. It no longer
carries the last answer's figure in the desktop app; the line under an unusual
answer stays as it was, and the entry is pinned in the same cases as before.

The cost is computed by the mod from each request's tokens in `turn.step`, the
same requests as the CO2, with `data/prices.json` and the formula and model
resolution of the bash plugin's `cost_usd` (`hooks/mod/lib/cost.ts`). `turn.step`
does not split cache writes by tier, so they are priced at the 1-hour tier,
the one Claude Code writes at. It shows with two decimals, `< 0,01 $` /
`< $0.01` under a cent, and is left out when `data/prices.json` cannot be
read, then until the total starts over: a part of the cost never shows as the
whole. `tests/run-mod-tests.mjs` replays the `expected_cost_usd` of both
golden-vector files through it, and the installers' copy of the mod now
carries `data/prices.json` beside `data/factors.json`.

### feat: /carbon-report gives a car equivalent and this year's share of a 2 t budget (1.10.0)

The equivalence block of `/carbon-report` printed four lines for the all-time
total (car, Gemini prompts, TGV or phone charges, beef steaks). It now prints
the car line of the detected locale set only, the same factor, label and source
as the cards, and a second line with the current calendar year's total as a
share of 2 tCO2e per person and per year: `Depuis le 1er janvier : 1 214 kg,
soit 61 % du budget annuel de 2 t par personne` on the French set, `Since
January 1: 1,214 kg, 61% of a 2 t per-person annual budget` on the US and world
sets, followed by the source. The share runs on this year's sessions only,
never on the all-time total. METHODOLOGY.md ("Annual budget line") quotes the
2 t figure from Carbone 4, _Faire sa part ?_ (June 2019), and ADEME's Nos Gestes
Climat (2025), and states that it is a 2050 target for a person's whole
footprint, used as a scale. `data/factors.json` is unchanged: the Gemini, TGV,
steak and charge rows stay there, unused by the report. `tests/run-report-tests.sh`
runs the skill against fixture databases, in CI on Linux and Windows.

### docs: install from the Claude desktop app, no terminal needed (1.10.0)

The README opens its install section with the desktop app: paste a message in the
Code tab and Claude runs the installer, with the line to expect under the prompt
and what to do when the install stops (the macOS developer tools window that
brings `git`, a missing `jq` or `sqlite3`, Git for Windows).

### feat: a Claude Code mod in the plugin shows the CO2 of each answer (1.9.0)

The plugin now holds a Claude Code mod (`hooks/mod/`, declared in
`hooks/hooks.json` beside the bash hooks; Claude Code 2.1.287 or later, 2.1.286
in the desktop app). It follows every model request through `turn.step`, main
loop and subagents, and computes its CO2 with the formula, factors
(`data/factors.json`) and model resolution of the plugin;
`tests/run-mod-tests.mjs` replays both golden-vector files in CI, and
`tests/run-mod-kit.sh` runs the mod's own tests under `claude plugin test`,
with Claude Code 2.1.296 pinned in CI.

In the terminal the CO2 of each answer sits at the right end of the turn
duration line, which keeps its own answer's figure when it is drawn again; a
line first drawn later than its answer, such as one only ctrl+o shows, keeps
the engine's text. In the desktop app's Code tab, where that line is not drawn,
it becomes a line under the answer, for unusual answers only: above the 97th
percentile of the last 200 answers, over three times their median and at least
10 g, once 50 answers are recorded (about one answer in 27). A toast shown
once per machine says the CO2 now shows for each answer, the same text on every
surface. The
session total is pinned under the prompt unless the claude-carbon status line
is configured or the `showSessionTotal` option is off, for a status line that
already shows the total such as ccstatusline with the claude-carbon segment;
the desktop app, which draws no status line, keeps it. In the desktop app that
entry also gives the last answer's CO2.
The mod writes every quantity as gCO₂ or kgCO₂. Background subagents, Claude
Code's default, count in the session total only,
never in an answer or in the median; a foreground subagent counts in the answer
that started it, and stops counting there once sent to the background. With
no locale variable set, as in the desktop app, the mod's language follows the
`language` setting (free text such as `Français` or `English`), then French; the
mod starts no process. The mod
draws nothing in the VS Code extension's chat panel, in cloud sessions or under
`claude -p`. It writes no database: the Stop hook keeps recording sessions.
The curl, PowerShell and npm installers, and `/carbon-update`, copy the mod
alone, with no command hook, to `skills/claude-carbon/` under the config dir,
where Claude Code loads it as `claude-carbon@skills-dir`
(`scripts/install-mod.sh`, run by `configure-settings.sh`).
`CLAUDE_CARBON_NO_MOD=1` skips the copy and removes it; a folder of that name
the installer did not make is left alone; the copy is skipped, or removed,
while the claude-carbon plugin is enabled. The copy is built aside and swapped
in by rename: one that cannot be replaced, such as a copy Windows holds open,
stays whole until a restart.

### feat: /carbon-card without Chromium opens the card in the browser, and the card says where to find the tool (1.9.0)

Without `playwright-core`, or with a Chromium that does not start (checked by
launching it), `scripts/generate-report.sh` no longer exits 1. It saves the
summary card as an HTML page in the export folder, logo inline and scaled down to
fit the window (the page clips its overflow, so a laptop screen shorter than
1080px could not reach the footer), and opens it in the default browser (`open` on
macOS, `explorer.exe` on Windows, `xdg-open` on Linux; skipped under
`CLAUDE_CARBON_NO_OPEN`, CI or without a display, where the line gives the page's
path instead), prints one line saying there is no PNG and a screenshot is enough,
with the install command, stamps `last-card-month` and exits 0. The PNG path now
stamps it only when at least one PNG was written.
The `Totals since ...` line now comes before the Playwright lookup, so both paths
print it. The PNG export is otherwise unchanged.

The footer of the four card templates reads `Mesurez la vôtre : claude-carbon sur GitHub`
(non-breaking space before the colon) and `Measure yours: claude-carbon on GitHub`, the
name in the card's orange, with `github.com/gwittebolle/claude-carbon` below
in smaller grey text. The TokenClimate team-view mention is unchanged.
`skills/carbon-card/SKILL.md` describes the browser path. After the card, the skill now encourages posting it and offers to help write the post, instead of writing a draft unasked.
`tests/run-portability-tests.sh` runs the script with no `playwright-core`, with
one that fails to load and with one whose Chromium fails to launch, found through
`NODE_PATH` as node finds any module (exit 0, the FR summary handed to a faked
opener, month stamped, Totals line first, no PNG, the page in the export folder
with its logo inline and its fit script, no temp page left; under
`CLAUDE_CARBON_NO_OPEN` nothing spawned and the path printed), with one whose
exports all fail (month not stamped), and pins the footer strings of both
templates in both languages.

### feat: the monthly nudge gives the closed month's total (1.9.0)

The status line nudge now reads `📊 September: 84.2kg CO₂ · /carbon-card` instead
of `📊 September wrapped · /carbon-card`. The figure is the previous month's total
from `carbon.db`, read only (the query of the card's monthly bar, excluded rows
left out), in the status line's own CO2 format: whole grams in `g CO₂`, one
decimal in `kg CO₂` from 1000 g. It is computed once a day and cached in
`last-month-total` under the config dir (`YYYY-MM-DD grams`, the key being the day
it was read): the Stop hook keeps adding to a session under its start date, so a
session running across midnight on the last day still grows the closed month after
the 1st. A locked or unreadable database is not cached and is retried.
A month with fewer than 7 distinct days of sessions caches `-` and shows no nudge.
The window (day 1 to `CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY`), the opt-out
(`CLAUDE_CARBON_NO_CARD_NUDGE`) and the `last-card-month` stamp are unchanged.
`run-install-tests.sh` drives the status line on throwaway databases: figure shown
with excluded and current-month rows left out, the cache written and reused with
no new query the same day, a cache from another day recomputed, fewer than 7 days giving no
nudge, no database giving neither nudge nor cache, the threshold, the stamp and
the opt-out.

### chore: the weekly snapshot also records npm downloads

`scripts/traffic-snapshot.sh` now also fetches the daily downloads of the
`claude-carbon` npm package for the last 365 days (the public
`api.npmjs.org/downloads/range` endpoint, no token) and merges them per day into
`stats/npm.json`, the latest fetch winning on days already stored, so a rerun
never counts a day twice. The zero days before the package first appears are left
out. A failed npm fetch, or an answer that is not the expected JSON, is skipped,
with no temp file left in `stats/`, and the GitHub snapshot is still written. It
runs in the same weekly `.github/workflows/traffic.yml` job, whose commit step
already adds `stats/`.

## 2026-10-09

### fix: Opus family priced as Opus 5.5

Claude Code's `opus` alias resolves to Claude Opus 5.5 on the Anthropic API
(code.claude.com/docs/en/model-config), launched 2026-09-22 at $4 / $20 with
cache reads at $0.20 (0.05x input), unchanged since. The Opus family price in
`data/prices.json` moves to 4 / 20. Opus 5, 4.8, 4.7, 4.6 and 4.5 are still
sold at 5 / 25 and keep it through new overrides. The family uses the global
0.1x cache-read multiplier, so the existing `claude-opus-5-5` override keeps
the 0.05x read; an Opus id without an override (Opus 4.1, 4 and 3, all
retired) is billed 4 / 20 with reads at $0.40.

Golden vectors: the six Opus vectors of `tests/methodology-vectors.json`
scale by 0.8 (CO2 unchanged, see `_reprice_2026_10_09_opus`);
`tests/methodology-vectors-per-model.json` gains Opus 5 and Opus 4.8 override
cases, and the `claude-opus-5-50` negative case moves to the new family price.

### fix: Haiku family priced as Haiku 5.5, Sonnet 5.5 cache reads at 0.05x

Anthropic launched Claude Haiku 5.5 on 2026-10-07 at $0.10 / $0.50 per million
tokens, cache reads $0.01, ten times below Haiku 4.5. Claude Code's `haiku`
alias now resolves to it (code.claude.com/docs/en/model-config), so the Haiku
family price in `data/prices.json` moves to 0.1 / 0.5 and Haiku 4.5 keeps 1 / 5
through a new `claude-haiku-4-5` override (dated ids like
`claude-haiku-4-5-20251001` included). The same day Anthropic cut Sonnet 5.5
cache reads from $0.20 to $0.10 (0.05x input): `claude-sonnet-5-5` gets an
override with `cache_read_multiplier: 0.05`. The Sonnet family stays at Sonnet
5's prices, since this file has one global cache-read multiplier. Pricing page
re-read 2026-10-09.

Haiku 5.5 bills 5x for a request whose prompt is over 100,000 tokens. That
tier is not modelled: such requests are under-billed up to 5x. Haiku 3.5 and
Haiku 3, both retired, have no override and fall to the new family price on a
`recompute.sh --with-cost`.

Golden vectors: the three Haiku vectors of `tests/methodology-vectors.json`
move to the new family price (cost divided by 10, CO2 unchanged, see
`_reprice_2026_10_09`); `tests/methodology-vectors-per-model.json` gains
Sonnet 5.5, Haiku 4.5 (plain and dated) and Haiku 5.5 cases. Emission factors
do not change.

## 2026-09-23

### feat: tokens are stored per model, message by message

A session used to be one row under one model. The CO2 and cost stored at insert
were right (each subagent file was priced at its own model), but anything that
read the row afterwards saw a single model: `recompute.sh` re-derived the whole
session at the main thread's model, and the per-model table of `/carbon-pr`
filed every subagent token under it. A new table, `session_models`, stores one
row per (session, model) with the same token columns, CO2 and cost. Each
assistant message counts under the model that produced it, so a `/model`
switch inside one transcript is now split too. The `sessions` row keeps its
meaning: totals, the main thread's dominant model, and CO2 and cost equal to
the sum over its models. Both tables are written in one transaction with a busy
timeout, since the SessionEnd hook's detached run can overlap a Stop hook.

`recompute.sh` re-derives each child row at its own model and sets the session
to the sum. Rows recorded before the table existed are no longer re-derived by
default: their stored CO2 and cost, computed at insert per file at each file's
model, are the best available, and re-deriving them at the dominant model
drifted by +44% cost and +16% CO2 on subagent-heavy rows (on one real DB, one
month's cost went from $2,509 to $4,394). `--include-unsplit` opts them in when
a factor or price changed and the approximation is acceptable; the installers
and `update.sh` never pass it. Legacy (`methodology_version` 1) rows are still
left alone. `backfill.sh` adds the per-model rows to existing sessions whose
transcript is still on disk and still yields the stored token totals; their CO2
and cost become the per-model sum. The carbon-pr table and the report's top
model read the split, with the row model as fallback. METHODOLOGY.md says which
rows are exact after a recompute and which are not.

### feat: prices per model where a model's price differs from its family's

`data/prices.json` gains `model_overrides`, matched on the exact id or the id
followed by a dated snapshot suffix (so `claude-opus-5-5` never catches a
`claude-opus-5-50`), longest key first. Opus 5.5 is billed at 4/20 with cache
reads at 0.20, Fable 5.1 and Mythos 5.1 at 10/50 with cache reads at 0.025x
input, and Sonnet 4.6, 4.5, 4, 3.7 and 3.5 at 3/15 (pricing page read
2026-09-23). Before, a Sonnet 4.6 session was under-billed by a third and Fable
5.1 cache reads were over-billed 4x. Emission factors stay per family; Opus 5.5
uses the Opus factors. The family detection that five scripts each carried is
now one function in `portable-lib.sh`. `tests/methodology-vectors.json` is
unchanged (it is the family contract, replayed with overrides off); the new
`tests/methodology-vectors-per-model.json` covers the resolution.

### perf: the Stop hook reads a session in one pass

The hook ran one `jq` per transcript plus about twenty `jq`/`awk` calls per
file. It now reads the main transcript and all subagents in one `jq` pass and
prices every model in one `awk`. On a synthetic 644 MB session (3,000 main
messages, 200 subagent files) it went from 17 s to 3.5 s; on a 15 MB session
with three subagents, from 0.45 s to 0.13 s.

### fix: an apostrophe no longer drops a session on macOS

The SQL quoting `"${X//\'/\'\'}"` keeps its backslashes under bash 3.2, the
`/bin/bash` of macOS, so a project, branch or model name containing an
apostrophe produced an invalid statement and the session was not recorded. The
quote is now doubled through a variable, which every bash version expands the
same way.

## 2026-09-21

### docs: two source attributions in the methodology say what the sources say

A full re-read of two sources cited in "Where the estimate stands" showed
wording that went further than the texts. The 4.3x attributed to Vellaisamy et
al. is a ratio computed from their Table V (548 to 2,358 mJ per output token,
Llama-3.1-8B on H200, batch 16, 512-token prompt, amortised prefill included),
not a figure the paper states, and the row now says so with its conditions.
Hausfather's three methods were described as "within a factor of ~5"; his own
wording is a 70 to 330 kWh range, uncertain by a factor of ~2 in either
direction, and the paragraph now uses it. No factor changes.

## 2026-09-16

### chore: the author line carries the accented name and the personal site

The README footer and `package.json` credited "Gaetan Wittebolle" with a
GitHub link only, while every other surface spells the name with the
diaeresis and points at gaetanwittebolle.com. Answer engines reconcile
entities on exact strings, so the footer now reads "Gaëtan Wittebolle",
links to the personal site and names TokenClimate as the team version. The
npm page picks up the new `author` at the next release.

### docs: what to do when the community-marketplace copy fails to load

The README's install section now says that the `co2-tracker@claude-community`
entry is pinned to an August 2026 release that current Claude Code rejects with
"Duplicate hooks file detected", and gives the two steps that fix it: uninstall
that plugin, then run the installer.

### feat: the badge is dated and links to the methodology

`/carbon-badge` now appends the month the snapshot was taken to the badge
message (`1139.2 kg CO2e, 2026-09`), and the markdown snippet links to
`METHODOLOGY.md` instead of the repository root. A reader of a README can tell
how old the figure is and how it was produced without leaving the badge. The
script's output ends with a note on where the badge belongs: it is one
developer's all-time total, so a profile README or a personal project, not a
team or organisation repository. `CLAUDE_CARBON_BADGE_MONTH` overrides the
month; the badge tests pin it to keep their expected URLs stable, and two new
assertions check the default month's shape and value. The README's own badge is
refreshed to the author's total as of September 2026 (1,208 sessions).

## 2026-09-10

### fix: the daily re-scan runs again on Linux and Windows

`cc_mtime` tried BSD `stat -f %m` first. GNU stat, which Linux and Git Bash
ship, reads that as a file-system status request, prints a multi-line block
for the file and then fails, so the fallback appended the epoch to that block.
`safety-rescan.sh` does arithmetic on the value to throttle itself to once a
day: once its stamp file existed, the script stopped there, and the daily
backfill never ran again on those platforms. The update check, which runs
before that line, was not affected. The status line's check of its OAuth usage
cache did the same arithmetic and failed the same way, on the path taken when
Claude Code does not pass rate limits in its input. `cc_mtime` now picks the
stat syntax by platform and returns 0 for anything that is not an integer. A
portability test pins it on each CI runner.

### fix: a session whose last turn is interrupted is still recorded in full

The Stop hook only runs when a turn completes. A turn interrupted with Esc,
followed by `/exit`, `/clear` or a closed terminal window, left that turn's
tokens out of the database for good, because the daily re-scan skipped any
session already recorded. Two changes close the gap. A `SessionEnd` hook
(`scripts/persist-on-exit.sh`) records the session once more as it closes. It
saves the hook payload and runs `persist-session.sh` detached, after a two
second wait for the transcript's last writes: SessionEnd hooks are killed after
1.5 s, and closing the window hangs up the process group. A payload carrying
`agent_id`, which only a hook running inside a subagent receives, is dropped:
that subagent's tokens already count in its parent's row. `backfill.sh` now
re-aggregates a recorded session whose transcript was written more than 60 s
after the row's `ended_at`, which covers a crash, a kill, or an exit where
SessionEnd did not run. The refreshed row keeps its `started_at` and `source`,
and its `ended_at` becomes the transcript's last write, so the next re-scan
does not parse it again. An unchanged session still costs a `stat`, not a
parse. Rows older than methodology version 2 are never refreshed. The hook is
declared in `hooks/hooks.json`, added by `configure-settings.sh` (so
`/carbon-update` wires it on clone installs), and listed in the README's manual
block and in `setup.sh`. The detach helper of `safety-rescan.sh` moves to
`portable-lib.sh` as `cc_detach`. New suite `tests/run-session-end-tests.sh`,
run in CI on Linux and Windows.

## 2026-09-07

### data: Sonnet list price is 2/10 (Claude Sonnet 5), re-read 2026-09-07

`data/prices.json` still carried Sonnet at 3/15, the price of Sonnet 4.6 and
4.5. Anthropic launched Claude Sonnet 5 on 2026-06-30 at 2/10 as an
introductory price and has since made it the standard price (the increase
to 3/15 scheduled for 2026-09-01 was cancelled). Since this plugin prices
per family, the family follows its current default model: Sonnet is now
2/10, and the note says plainly that a Sonnet 4.6 session is under-billed
by a third. Fable 5.1 and Mythos 5.1 bill cache reads at 0.025x input
instead of 0.1x; the plugin has a single `cache_read_multiplier`, so this
is documented as not modelled rather than approximated. The golden vectors
move on `expected_cost_usd` only (three Sonnet vectors); no CO2 value
changes. After updating, run `scripts/recompute.sh --with-cost` to
re-derive `cost_usd` on stored rows.

### docs: the "Reduce your footprint" section explains each lever, without percentages

The README keeps a short version, one line per lever with its command, and the
long form with mechanisms and sources moves to `docs/reduce.md`. The section listed levers with an estimated reduction each and a combined
"-50 to 70%" figure. Those figures came from the tools' own documentation or
from arithmetic on this tool's factors, whose uncertainty band is wider than
any of them. The section is rewritten by mechanism: it opens with the
observation that almost all tokens of a session are cache reads and that the
energy of a generated token grows with the context it is generated in, then
gives each lever its direction and its physical reason. New levers: keeping
the context short when the model generates (one session per task, `/clear`,
`/btw`, scoped investigations, subagents for broad low-context work), not
breaking the prompt cache mid-session, fewer turns and failed loops, asking
the agent only what needs an agent, the fixed cost per request, deterministic
tools over retries, the length and language of the answer, and the effort
level per task type, and a note that the harness itself decides most of
these. The intro says to compare several sessions, not one. Three facts are
aligned with the current Claude Code docs: MCP schemas are deferred by
default, editing CLAUDE.md mid-session neither breaks the cache nor applies,
and the auto-compact window is set with `/autocompact` (the percentage
override the section used to show is no longer documented). The thinking
snippet becomes `/effort`, since adaptive-reasoning models ignore a token
budget.
Compaction is described as a trade-off (the summary is generated output and
re-writes the cache) rather than a free gain, and unused MCP servers as
overhead at every decode step rather than a modest cached cost. A "What does
not hold up" list covers shell output filters, prompt compressors that
invalidate the prefix cache, and the addition of percentages; the tool that was
recommended by name is no longer cited. The closing section says the grid is
out of the user's hands for now, and that trying other models on part of the
work is a lever too. The combined-impact table is removed. The settings
snippets are unchanged.

## 2026-09-04

### docs: the README says in a sentence what the tool is

The README carried the name only in code blocks and URLs, and nothing under the
badges said in plain words what claude-carbon does. The GitHub description now
starts with the name, the intro under the badges is one sentence that says what
the plugin is, the feature list moved up under the demo GIF as "What
claude-carbon does", the data-flow diagram has a descriptive alt text, and the
npm keywords grew from 6 to 14 (they reach npm at the next publish).
Discussions are enabled on the repo. Nothing that runs on a user's machine
changed.

### chore: CITATION.cff follows the release version

GitHub's "Cite this repository" reads `CITATION.cff`, which still said 1.1.1,
released 2026-07-19, five releases and six weeks behind. It now says 1.6.0 and
the tag's date, `release.sh` rewrites both lines on every bump, and
`check-versions.sh` fails when the file disagrees with the three manifests, the
way it already did for those three.

### feat: store the decode-context term, and date the methodology against the 2026 literature

Each generated token re-reads the whole KV cache, so its energy grows with the
context it is generated against, and batching does not amortise that part (weights
are shared across a batch, each request's cache is not). The formula has no such
term: the output factor is a constant calibrated on Jegham's points at 10k context
or less, while the median Claude Code message here carries 160k. Measured on open
models the term is x2.3 per output token from 1k to 16k context on GQA, and nothing
is measured beyond. On the author's own 30 days a term of the form
`output x (1 + context / C0)` moves the total by x1.3 to x5.6 depending on C0, more
than every other parameter combined.

No slope can be defended today, so no factor moves. What changes is that the data
stops being lost: every session now stores `output_context_sum`, the sum over its
assistant messages of `output_tokens x (input + cache_write + cache_read)`, after
the same dedup as the token counts, main transcript and subagents alike. Both
writers (`persist-session.sh`, `backfill.sh`) add the column to an existing DB, and
`backfill.sh` fills it on rows that predate it while their transcript is still
inside the 30-day window. No formula reads it yet; CO2 and cost are unchanged.

METHODOLOGY gains a dated section, "Where the estimate stands (September 2026)":
each parameter against what was published between April and September 2026
(Oviedo et al. in Joule, the Watershed framework, four HotCarbon 2026 papers, the
Amazon and Google 2026 reports), the swing it produces on the same 30 days, and
the decision. The output factor sits 2-3x above production-conditions figures and
the input factor 2.6x below Watershed's; rebalancing either without the context
term would be cosmetic, so both stay. The Colossus line in Limitations is brought
up to date (Anthropic took the whole site in May 2026). The README now points at
that section. `run-install-tests.sh` covers the new column through both writers,
the fill pass and its idempotence; the Windows end-to-end run checks it too.

### docs: a social preview rendered from the demo, and a demo prompt a newcomer recognises

`docs/social-preview.gif` (1280x640, the GitHub "Social preview" format) puts the
animated status line under the project name on the brand ground (cream, the 56 px
rule grid and orange glow of tokenclimate.com, Clash Display and Owners, drawn by
`docs/demo/social-preview-bg.py`), composed from `docs/demo.gif` by
`docs/demo/render-social-preview.sh` so it cannot drift from the real status line
the way the data-flow diagram once did; `docs/social-preview.png`
is the last frame for hosts that show a still. The demo prompt was "recalibrate the
emission factors and replay the golden vectors", the project's own jargon, which
read as if the tool recalibrated something. It is now "fix the flaky integration
test and open a PR": an ordinary task, so the status line is the only thing left
to notice. In the recording the CO2 figure is tinted brand orange; the real status
line stays uncoloured, it sits in every terminal all day and an orange segment
there would be glare.

## 2026-09-03

### feat: the monthly nudge names the month it wraps, and stays through the 10th

The status line used to show `📊 /carbon-card` to the first three sessions of the
month and then stop: two or three glances at a command name, with no hint of what
the card would show. Nobody acted on it.

It now reads `📊 August wrapped · /carbon-card` (English whatever the locale, like
the rest of the line), on every session from the 1st through the 10th, until a
card is generated. The month just closed has its bar on the summary card under
the running total, which is the thing worth sharing. `CLAUDE_CARBON_CARD_NUDGE_UNTIL_DAY`
moves the cut-off (default 10); `CLAUDE_CARBON_NO_CARD_NUDGE` still opts out.
`CLAUDE_CARBON_CARD_NUDGE_SESSIONS` and the `card-nudge-seen` file are gone; an
existing file is simply no longer read.

`cc_prev_month_name` joins `portable-lib.sh` (pure string arithmetic, no `date -d`
or `date -v`, pinned on fixed inputs including the January wrap-around), and
`run-install-tests.sh` drives the status line through the four cases: shown with
the right label, gone past the threshold, cleared by a card, silenced by the opt-out.

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

### feat: cards land in ~/Downloads/claude-carbon and the folder opens by itself

A user generated their first card and could not find it. The PNGs were written
to `<repo>/exports/`, which is buried in `~/code` on a curl install and, on a
marketplace install, sits inside `~/.claude/plugins/cache/.../<version>/`: a
hidden directory that changes on every update, orphaning the previous cards. The
script then printed the path in Git Bash spelling (`/c/Users/...`) and did
nothing else.

- `generate-report.sh` exports to `<Downloads>/claude-carbon/`. `cc_downloads_dir`
  asks the authority each platform has: the Downloads known folder in the Windows
  registry (so a OneDrive-redirected folder is honoured), `xdg-user-dir DOWNLOAD`
  on Linux, `~/Downloads` on macOS and as the fallback everywhere.
  `CLAUDE_CARBON_EXPORT_DIR` overrides it.
- After the export, `cc_reveal` opens the folder in the file manager: Finder with
  the summary card selected on macOS, Explorer on Windows, the default file
  manager on Linux. Silent when there is no display, in CI, or when
  `CLAUDE_CARBON_NO_OPEN` is set. Never fails the script.
- The per-file lines and the final `Done.` line print the path in the platform's
  native spelling, so what the user sees is what they can paste.
- `/carbon-card` tells the user the folder is open in front of them.
- The local file server is disowned after launch. bash used to announce its kill
  at exit with a "Terminated" notice quoting the whole node command, twenty lines
  of JavaScript after the `Done.` line in every run.

`tests/run-portability-tests.sh` exercises every branch of both helpers with the
platform forced and the authority faked on PATH (a `reg` answering an unexpanded
`%USERPROFILE%\OneDrive\Downloads`, an `xdg-user-dir` answering `$HOME`), and
checks `cc_reveal` spawns the right tool with the right argument, or nothing when
it must not.

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
whose name contains a space (`~/My Projects/claude-carbon`) it split into filenames
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
- skills: fixed REPO_DIR resolution when `statusLine.command` contains a shell-escaped path (e.g. `~/My\ Projects/...`): tilde and escaped spaces are now expanded, so /carbon-card and /carbon-update run the install actually wired into the statusline instead of falling back to `~/code/claude-carbon` or the plugin cache.

### docs: CITATION.cff and a Citing section in the README

License stays plain MIT. Citation is encouraged, not required: CITATION.cff enables GitHub's "Cite this repository" button, the README documents the short form, and the report cards keep carrying the repo + tokenclimate.com attribution in their footer.

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

GitHub's traffic API only keeps a 14-day rolling window, so `scripts/traffic-snapshot.sh` merges per-day views/clones into `stats/traffic.json` (latest fetch wins on overlapping days) and appends dated referrer/path snapshots as JSONL. Runs Mondays via `.github/workflows/traffic.yml` (workflow_dispatch too); needs a `TRAFFIC_TOKEN` fine-grained PAT secret with repository Administration read, because the traffic endpoints reject the default Actions token. Seeded with the current window.

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
- `.gitignore`: `promo/` (local drafts stay out of the repo).

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

The OSS points to the hosted layer in two places, without any ambient nagging or data collection:

- `/carbon-report` ends with a single footer line: `Team view (same methodology): tokenclimate.com`.
- The four `/carbon-card` PNG templates carry a small muted credit under the open-source badge (`vue équipe · tokenclimate.com` / `team view · tokenclimate.com`), so shared cards surface the link to viewers.
- Deliberately no status-line promo and no email capture: the update notice stays the only status-line extra.
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

Stars, license, and release badges.

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
