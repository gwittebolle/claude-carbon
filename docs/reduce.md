# Reduce your Claude Code footprint

The long form of the README's [Reduce your footprint](../README.md#reduce-your-footprint) section: the mechanism behind each lever, its direction, and the sources.

Measuring is step one. The levers below are ordered by what the 2026 measurement literature and this tool's own sensitivity run on 30 days of real transcripts say matters most. None of them comes with a percentage: the emission factors carry a wider uncertainty band than any gain figure would. Each lever states the mechanism and the direction. The magnitude depends on your workload, and `/carbon-report` before and after a change is the measurement that applies to you. Compare over several sessions rather than one: two runs of a coding agent on the same task can differ by up to 30x in tokens, and the model's own estimate of what a task will cost is a poor guide ([Bai et al.](https://arxiv.org/abs/2604.22750)).

## Keep the context short when the model generates

In a Claude Code session, almost all tokens are cache reads: about 96% in [Hausfather's eight-week log](https://www.theclimatebrink.com/p/the-real-energy-use-of-agentic-ai), 97.5% in this tool's own transcripts. The agent re-reads its whole context at every step. Measurements on GPUs show that the energy of one generated token grows with the length of the context it is generated in ([Ma et al.](https://arxiv.org/abs/2605.11999), [Vellaisamy et al.](https://arxiv.org/abs/2608.28044)): the same output token costs more late in a long session than early in a short one. This tool's factors are flat per token, so the effect is not in the displayed figure; in the sensitivity run it outweighs every other parameter (see [METHODOLOGY.md](../METHODOLOGY.md#where-the-estimate-stands-september-2026)).

In practice, and this is also what [Anthropic's own guide](https://code.claude.com/docs/en/best-practices) recommends for quality reasons: one session per task rather than one session for the day, `/clear` when the subject changes, `/btw` for a side question whose answer should not stay in the history, and a narrow scope for investigations ("look at `src/auth/`" rather than "investigate the codebase"). When a large feature starts with a spec, write the spec in one session and implement it in a fresh one. `/context` shows what the current session carries, by category.

A million-token window makes this lever matter more, not less. On models that run at 1M by default, auto-compaction only triggers near the top of that window, so a session left alone grows to a context several times what a 200k model would ever reach. Setting a smaller auto-compact window (see below) keeps the generation context bounded whatever the model allows.

Subagents help when the work is broad and needs little context: exploration, wide searches, a review of a diff, a verbose operation such as a test run or a log scan. They read what they need in their own context and hand back a conclusion, so the main session never carries the files. Each of them also loads its own system prompt, `CLAUDE.md` and tool set, none of it shared with the main session's cache, so a subagent on a small, context-heavy task costs more than doing it in place.

## Compaction is a trade-off, not a free gain

Compaction (automatic near the top of the window, manual with `/compact`) has the model write a summary of the session so far. That summary is generated output, and the turn after it rebuilds the conversation cache on the shorter history. While the cache is warm, the summarisation request reads the existing prefix from cache, so a mid-session `/compact` costs a fraction of what the context size suggests; after a break longer than the cache lifetime, it reprocesses the whole history uncached, which is why compacting a resumed old session is the expensive case. In a long session the trade pays off, because every later output token runs in a smaller context. In a short one it does not.

Three ways to get more out of it, all from [Anthropic's prompt caching page](https://code.claude.com/docs/en/prompt-caching): `/compact <instructions>` to say what must survive, so the next turns do not re-read it; the rewind menu's "summarize from here" to condense only the part that is done; and `/rewind` instead of `/compact` when you are abandoning a path, since rewinding truncates back to a prefix that is already cached rather than building a new one. To compact earlier than the default, set the auto-compact window in tokens:

```text
/autocompact 150k
```

The same value goes in `CLAUDE_CODE_AUTO_COMPACT_WINDOW` for every session, and `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` keeps 1M-capable models at the 200k boundary.

## Trim what every turn carries

The system prompt, `CLAUDE.md` (global and project), auto memory and the one-line descriptions of skills and MCP tools are in the context of every request. They are served from the prompt cache, which is cheap at prefill, but every generated token reads them again at decode time. `/context` lists them with their size.

MCP tool schemas are deferred by default: only the tool names and server instructions enter the context until a tool is used. Leave it that way (`ENABLE_TOOL_SEARCH=false` loads every schema upfront), and disable servers the project does not use with `/mcp`. A CLI such as `gh` or `aws` is still lighter than an MCP server, since it adds no listing at all.

`CLAUDE.md` is loaded every session, so it should hold what applies to every session and nothing Claude can derive from the code. Knowledge that only some tasks need belongs in a skill, which is loaded on demand. Two more ways to cut what enters the context, from [Anthropic's cost page](https://code.claude.com/docs/en/costs#reduce-token-usage): a code intelligence plugin, so a "go to definition" replaces a grep plus several candidate file reads, and a hook that filters tool output before Claude sees it, such as a test run reduced to its failures.

## Do not break the cache mid-session

Prompt caching is what makes the re-read tokens cheap, and it only works on an unchanged prefix ([Don't Break the Cache](https://arxiv.org/abs/2601.06007)). Claude Code orders each request so that what rarely changes comes first, and [documents what breaks it](https://code.claude.com/docs/en/prompt-caching#actions-that-invalidate-the-cache): switching model, changing effort level (except on Fable 5.1 with a subscription or API key), turning on fast mode, denying a whole tool, accumulating many images, upgrading Claude Code, and resuming a long session after the cache has expired. Each of those makes the next request reprocess the entire history uncached. Pick the model and effort at the top of a session, and make the other changes between sessions. Editing `CLAUDE.md` mid-session does not break the cache, but it does not apply either until the next `/clear` or restart. `/usage` shows the session's cache hit ratio and the likely cause of the last miss.

## Fewer turns, fewer failed loops

Cache reads scale with the number of tool calls. An agentic coding task runs tens of them, and a failed attempt costs about twice a successful one ([AgentStop](https://arxiv.org/abs/2605.15206)). A written spec before the work, tests the agent can run as its own oracle, and one well-scoped agent instead of several parallel ones on a trivial question all cut the number of steps. After two failed corrections on the same issue, the context is full of failed approaches: `/clear` and a better first prompt cost less than a third try. Every request also carries a fixed cost that does not depend on its length ([Vellaisamy et al.](https://arxiv.org/abs/2608.28044)), so one full prompt beats a trickle of one-liners. Where a deterministic tool can do the step, a linter, a test runner, a CLI such as `gh`, a hook, let it: on tool-backed tasks the orchestration overhead of an agent drops below that of a straight-line run, and it is retries, not model compute, that inflate the energy per completed task ([Energy per Successful Goal](https://arxiv.org/abs/2605.22883)). Plan mode is worth it when the approach is uncertain or the change spans several files, and is overhead when the diff fits in one sentence. Hausfather: "There is a real difference between pointing five parallel agents at a hard research problem and doing the same to settle a bar bet."

An idle session is not free either: a `/loop` or scheduled task, a goal check-in, or a message from another session each start a turn that sends the full context. A session left open all day with a loop running pays for its whole context at every firing.

## Ask the agent only what needs an agent

A study of a public dataset of developer prompts ([Sustainable AI Assistance Through Digital Sobriety](https://arxiv.org/abs/2603.29222)) found that about half of the queries brought little relative to their cost, most of them factual lookups that a search engine or the local documentation would have answered. In Claude Code, such a question is not one call: an agentic task runs on the order of a thousand times the tokens of a chat exchange ([Bai et al.](https://arxiv.org/abs/2604.22750)), because every step re-reads the context and the agent opens whatever it decides to open. A man page, a `--help`, or the project's docs cost nothing.

## Match reasoning to the task

On reasoning models the hidden trace is most of the output tokens, and the energy per output token is the same inside and outside the trace ([Pasandi & Nadeem, HotCarbon 2026](https://hotcarbon.org/assets/2026/paper-102.pdf)). In their measurements, capping the trace on routine tasks costs little accuracy, and in production measurements a small share of long reasoning requests accounts for a large share of the energy ([Oviedo et al.](https://arxiv.org/abs/2509.20241)). The lever is the effort level per type of task, not a "be concise" instruction, which only shortens the visible answer. Set it at the start of the session, since changing it later breaks the cache on most models:

```text
/effort low
```

The same goes in settings as `effortLevel`, or per model under `modelSettings`. On models with a fixed thinking budget, `MAX_THINKING_TOKENS` caps the trace instead; adaptive-reasoning models ignore it, and Fable models always think.

Output length still counts, since the energy of an agentic coding run grows in proportion to it ([Ifath & Haque](https://arxiv.org/abs/2604.09611)). One thing that changes it without changing what is said is the language of the answer: the same content takes fewer tokens in English than in most other languages, by a margin that depends on the language ([Language-Energy Divide](https://arxiv.org/abs/2606.21869)). Code, comments and commit messages in English are the cheap default; a conversation in your own language is a choice you can make knowingly.

## Match the model to the task

After context, the Opus multiplier is the largest term in the sensitivity run, and a smaller model uses several times less energy per token. Opus for architecture and planning, Sonnet for daily work, Haiku for subagents:

```json
{
  "env": {
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-haiku-4-5"
  }
}
```

## The harness is a lever too

Most of the levers above are decisions the harness makes for you: what sits in the system prompt, which tools are listed and how, when tool output is truncated, when the context is compacted, whether tools are deferred to keep the cached prefix stable. Anthropic describes Claude Code's design as [organised around the cache](https://claude.com/blog/lessons-from-building-claude-code-prompt-caching-is-everything). Holding the model constant and varying only the harness changes both the tokens spent and the success rate, as shown across successive releases of a single coding agent ([Don't Blame the Large Language Model](https://arxiv.org/abs/2607.03691)). The cross-harness figures in circulation, one agent using several times the tokens of another on the same task, compare a different model in a different harness, so they do not isolate either. Two things follow. A harness upgrade can move your footprint without any change on your side, which is one more reason to compare over several sessions. And the harness is a choice like the model is: this tool only counts Claude Code, so a session run elsewhere is missing from its reports, but the provider's own token counts let you measure that side.

## What does not hold up

- **Shell output filters.** Claude Code reads files with its own Read and Grep tools, which never go through a shell hook, and it already truncates long tool output. The share of a session such a filter can touch is small, and the token count it reports is its own counterfactual, not your bill. Measure on your sessions before trusting an advertised figure.
- **Prompt compressors.** A compression that changes with the request invalidates the prefix cache on every call ([Song, 2026](https://arxiv.org/abs/2607.15516)), which can cost more than it saves. Task-aware pruning of code context works inside research scaffolds ([SWE-Pruner](https://arxiv.org/abs/2601.16746)), but it is not a setting you can turn on.
- **Adding up percentages.** Earlier versions of this section summed per-lever reductions into a combined figure. The levers act on different token pools, and the factors' uncertainty band is wider than the sum.

## Out of your hands, for now

The carbon intensity of the grid behind the data centre is the largest term of all: Hausfather puts the same workload on a mostly clean grid at roughly a tenth of the emissions. Claude Code offers no region choice. The factor this tool uses, and why, is in [METHODOLOGY.md](../METHODOLOGY.md).

Nothing ties your work to one provider, though. Other models run on other grids, some providers publish a measured energy per request where Anthropic publishes none, and a small or local model may do the job on a trivial task: a measurement study of coding-agent workloads found that routing the simple requests to a local model, with the cloud model kept for the rest, removes a large share of the cloud tokens ([Local-Splitter](https://arxiv.org/abs/2604.12301)). A local model still draws power on your machine; [CodeCarbon](https://github.com/mlco2/codecarbon) measures that side. Trying other models on part of your work is a lever too, even if this tool only counts the Claude Code side.
