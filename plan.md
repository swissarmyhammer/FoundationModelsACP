# Plan: FoundationModelsACP — the ACP agent composed over the harness

> **Reborn 2026-07-21.** This repo was slated for retirement when its wire
> layer was inlined into the harness; the harness's re-scope into a
> constructor-fed loop then left the composition layer (config, commands,
> frontends, ACP) homeless in a `product_plan.md`. This package is that
> layer's home: **FoundationModelsACP layers over FoundationModelsAgentHarness
> and FoundationModelsRouter, and adds slash-command support and
> configuration.** Everything the harness deliberately refuses to own — file
> I/O, dotfolders, command registries, the wire — lives here.

## Layering

```
editors (Zed, …) ──ndJSON/stdio──┐          CLI / Mac app (thin frontends,
                                 │           consume the composition directly)
                                 ▼                        │
                      FoundationModelsACP  ◄──────────────┘
                      │  config (Extras: DotfolderStack + TemplateEngine, §4)
                      │  AGENTS.md assembly (Extras: AgentsMd, §6.1)
                      │  slash commands + registry + dispatch (§6.2)
                      │  tool roster: config sections → real tools (§7)
                      │  transcript location policy (§5)
                      │  HarnessACPAgent: the Agent conformance (§9.1)
                      │  the wire target: types/connections/ndJSON (§9.2)
                      ▼
        FoundationModelsAgentHarness (the loop: tokens, compaction, events)
                      ▼
        FoundationModelsRouter (models, sessions, recording, restore, compact)
                      ▼
        FoundationModelsExtras (stack, templating, SlashCommand, AgentsMd)
```

Two targets:

- **`FoundationModelsACP`** (the wire) — generated schema types, `Agent`/
  `Client` role protocols, connections, ndJSON framing. **Zero dependencies**
  (§9.2), exactly as specced when it was to be inlined; it is simply this
  package's first target again.
- **`FoundationModelsACPAgent`** (the composition) — depends on the wire
  target, the harness, Router, Extras, and the tool packages the roster
  names (`FoundationModelsFileTool`, `FoundationModelsShelltool`, … — §7).
  Naming tool packages is *this* package's job precisely because the harness
  may not: nothing cycles, since no tool package (and not the agents tool)
  ever depends on ACP.

The composition, end to end:

```
config  (dotfolder stack, §4)
  → ProfileDefinition → Router.resolve → resident profile
  → tools         (roster §7: config sections → constructed, confined tools)
  → instructions  (builtin prompt + AGENTS.md §6.1 + config replace/append)
  → compaction    (coding-tuned CompactionPrompt + TokenBudget)
  → Harness(router:tools:instructions:compaction:)      ← the reusable loop
  → HarnessACPAgent(harness:commands:)                  ← §9.1, + registry §6.2
```

## Decisions made at rebirth

- **ACP is the composition layer** — supersedes both "the product layer
  awaits a home" and the interim idea of a raw adapter directly over Router.
  The noun test lands three ways now: session storage/restore nouns are
  Router's, turn/loop nouns are the harness's, and commands + configuration
  + the wire are this package's. The conformance composes `Harness`/
  `HarnessSession`, so every loop behavior (auto-compaction, budgets, retry,
  events with correlation ids) works over ACP with zero wire-specific code.
- **Slash-command dispatch lives at the prompt owner.** The old "dispatch
  lives in `run()`" died with the harness re-scope (the loop no longer knows
  commands exist). The prompt owners are this package's `prompt()` handler
  and the frontends' composers; each routes a leading `/name` through the
  registry before anything reaches the model. A `/compact` typed in an
  editor must **never** become a model prompt. Registry mechanics (merge,
  precedence, near-miss matching, `commandUpdates` re-publication) live in
  this package; the cross-package *vocabulary* (`SlashCommand`/
  `SlashCommandProviding`) stays in Extras where conformers can reach it.
- **Builtin commands bind to session surface, not harness internals**:
  `/compact` → `session.compact()`, `/context` → usage/fill, `/status` →
  session id/cwd/model, `/help` → the registry. Dotfolder template commands
  (`commands/*.md`) are loaded here (Extras stack + untrusted Stencil) as
  `.prompt`-only; `.action` still requires linked Swift — the trust boundary
  travels intact.
- **Configuration is this package's** (§4): the dotfolder name, the YAML
  schema (`AgentConfiguration`: `profile` with standard/flash/**embedding**
  slots, `tools` built-in + `mcp`, `instructions`, `recording`,
  `transcripts`, `compaction`), defaults directory, template-first
  rendering, and the mapping onto Router types. The harness never sees any
  of it — it receives values.
- **Loading is Extras' (decision 1b).** Yams fights its way into Extras: a
  `LayeredYAMLDocument` beside the stack loads → renders (trusted defaults,
  untrusted user/project) → **merges with the family's one rule** (scalars
  and arrays replace wholesale, sections merge by key) → returns a value
  tree with per-key source tracking; this package decodes it via `Codable`.
  Merge semantics live with the thing that defines the layers, written once
  for ACP config, Shelltool's `ShellPolicy`, and future Skills use.
- **The built-in roster is linked packages under well-known names.** ACP
  links the family's tool packages and reserves one config section per tool:
  `files:` (FoundationModelsFileTool), `shell:` (FoundationModelsShelltool),
  later `codeContext:`, `multitool:`, `skills:`, `agents:`. Presence
  enables; the section body decodes as **that package's own option type**.
  Unknown top-level sections warn (forward compatibility); MCP is the
  escape hatch for tools we don't link. This is the pre-pivot `ToolCatalog`
  "add tools here and only here" location, relocated to the one package
  allowed to name tool packages.
- **MCP transport is FoundationModelsMCP's job, not ours.** Config's `mcp:`
  entries carry either `command` (+args/env — the MCP package spawns and
  owns the stdio subprocess) or `url` (http/s client connect); ACP passes
  the entry through to `MCPToolProvider` and receives `[any Tool]`. Process
  lifecycle, reconnects, and pooling across sessions are upstream asks on
  FoundationModelsMCP — recorded there, not reimplemented here.

---

> The sections below were extracted from the pre-pivot harness plan (via its
> interim `product_plan.md`) and keep their original numbering (§4–§10.1)
> for traceability; renumber in a later editing pass. Where prose says "the
> harness" doing composition-flavored work, read "this package" — the
> highest-value corrections are already applied inline (§6.2 dispatch, §9.1
> framing).

## 4. Configuration

### The pluggable dotfolder

The frontend passes a bare name (no dot). `DotfolderStack` — **Extras'** type
now (moved out of this package so the whole family layers files one way;
Shelltool's stacked `ShellPolicy` is the candidate second adopter). Shipped as
`init(name:workingDirectory:defaultsDirectory:userDirectory:environment:)` —
`userDirectory` and `environment` are injectable so tests and demos never
touch the real home — it derives the locations and the precedence order:

1. **Builtin defaults** — a *directory of real files*, never compiled-in
   content (the swissarmyhammer lesson: embedded builtins meant a recompile to
   edit markdown — Extras plan §1). A curated coding-model profile that works
   out of the box on a 16 GB machine (`recording.level: full`,
   `transcripts.location: home`), materialized on first run, with a
   `<NAME>_DEFAULTS_DIR` override so development edits never involve a build.
2. **User layer** — XDG, as Extras shipped it: `$XDG_CONFIG_HOME/<name>/config.yaml`
   when that variable is set and absolute, else `~/.config/<name>/config.yaml`
   (machine-wide preferences; bare `<name>` under a config dir — the
   hidden-file dot convention doesn't apply there).
3. **Project layer** — `$CWD/.<name>/config.yaml` (per-repo overrides; `$CWD` here is
   the agent's working directory, not the process cwd).

Missing files are fine; a present-but-malformed file is a hard, early error naming the
file and line (never silently fall back over a typo'd config). Merge semantics are
**key-level override**: scalars and arrays replace wholesale when the later layer
defines them; sections merge by key. Wholesale array replacement matches the family's
full-replace override rule (Skills' `FolderStack`) and keeps "which models am I
running?" answerable by reading one file.

**Every dotfolder document is a template first.** Before decoding, each file
renders through Extras' Stencil-backed `TemplateEngine`: `{{ variables }}`
from a provided `TemplateContext`, env vars, and well-known values (dotfolder
name, cwd, date) on the swissarmyhammer ladder (context > env > well-known),
plus `{% include %}` partials from the stack's `_partials/` (nearest layer
wins). Defaults render *trusted*; user/project layers *untrusted* (validated,
side-effect-free — no filesystem or exec capability — and metered, as built:
include-depth, loop-iteration, and output-size budgets). One rule
for every format — config YAML, command templates and frontmatter (§6.2),
instructions and memory (§6.1): **render the whole file, then parse**, so
even frontmatter values can be templated.

### Schema (v1)

```yaml
# ~/.config/<name>/config.yaml  or  <project>/.<name>/config.yaml
profile:
  name: coding                    # optional; defaults to the dotfolder name
  standard:                       # candidate lists, biggest-first, "org/repo@rev"
    - mlx-community/Qwen2.5-Coder-32B-Instruct-4bit
    - mlx-community/Qwen2.5-Coder-14B-Instruct-4bit
    - mlx-community/Qwen2.5-Coder-7B-Instruct-4bit
  flash:
    - mlx-community/Qwen2.5-Coder-3B-Instruct-4bit
  embedding:
    - mlx-community/bge-small-en-v1.5-4bit

tools:
  files: {}                       # well-known built-ins (§7): presence enables;
  shell:                          #   the body decodes as that tool package's
    policy: strict                #   own option type
  mcp:                            # MCP servers — FoundationModelsMCP owns the
    - name: github                #   transport: `command` spawns a stdio
      command: ["npx", "-y", "@modelcontextprotocol/server-github"]
      env: { GITHUB_TOKEN: "{{ env.GITHUB_TOKEN }}" }   # templated (untrusted layers)
    - name: internal-docs
      url: https://mcp.example.com/sse                  # http/s client connect

recording:
  level: full                     # off | metadata | full → Router's RecordingLevel

transcripts:
  location: home                  # home | project | /absolute/path   (§5)

instructions:
  replace: |                      # optional: swap out the builtin system prompt
    You are a code-review assistant. # entirely — this text becomes the base
  append: |                       # optional: extra text appended after the base
    Prefer swift-testing over XCTest.   # (the builtin prompt, or replace: if set)
```

Everything maps 1:1 onto existing Router types (`ProfileDefinition`, `ModelRef`'s
`"org/repo@rev"` Codable form, `RecordingLevel`) — the config layer is a codec, not a
model. Unknown top-level keys warn (forward compatibility for tool sections, §7.3);
unknown keys *inside* known sections are errors (typo protection).

**System prompt: a clear, published artifact.** The builtin coding instructions are
not a hidden string — and not a compiled-in one either: they ship as
`Instructions.md` in the defaults directory (layer 1 above; editable like any
file), reproduced verbatim in DocC/README, and surfaced at runtime
(`Harness.instructions` exposes the fully assembled prompt; the CLI prints it with a
flag) — so users always know exactly what `replace:` is replacing. Assembly is:
base = `instructions.replace` if set, else the builtin prompt; then the
session's memory files (user then project — §6.1); then `instructions.append`
last. Each config key follows the normal layer rules independently — a
project-layer `replace` overrides a home-layer `replace` wholesale, and
`append` composes with whichever base won.

**Context size is deliberately not configurable.** It is derived from the model
automatically: Router already fetches each candidate's HF `config.json` during
sizing, which carries the model's native maximum (`max_position_embeddings`), and its
joint-fit already prices KV-cache-per-context against the host budget. Deriving
context where that metadata already lives is a small upstream change (§8, item 2);
users pick models, the system picks the context they can afford.

`AgentConfiguration` is `Codable + Sendable + Equatable`, constructible in
tests without any file I/O. Loading is Extras' `LayeredYAMLDocument` over the
stack (decision 1b, head): locate → render → merge with the family's one
rule, per-key source tracking — Extras remains the only thing that touches
disk, and merge semantics are written exactly once family-wide.

## 5. Transcripts: where recordings live

**Decision: home, keyed by project — `~/.config/<name>/transcripts/<project-slug>/`,
under the stack's user-layer root (XDG-derived, §4) — with a
config escape hatch.** Consulting Router settled it:

- Router's layout is `<recordingsDir>/<routerId ULID>/…` with a fresh router id per
  run. In a *project-local* dotfolder that means an ever-growing pile of opaque ULID
  directories accumulating in every repo you ever pointed the agent at, each needing
  `.gitignore` protection. In one home location it's just history.
- The stated requirement is that the Mac app and the CLI **share** transcript
  recording. The app's session browser wants to enumerate *all* projects' sessions
  from one root ("what was I doing in repo X last week?"). One home root makes that a
  directory walk; per-project storage makes it a filesystem-wide hunt.
- Transcripts at `RecordingLevel.full` contain complete prompts, file contents fed to
  tools, and model output. That is exactly the class of artifact that must never ride
  along in a repo — gitignored or not (archives, `git add -f`, backup tools).
- Transcripts must survive the repo. Deleting a checkout shouldn't delete the record
  of what the agent did to it.

Layout — the harness owns the two segments above Router's root, Router owns everything
below, unchanged:

```
~/.config/<name>/transcripts/
    -Users-wballard-github-swissarmyhammer-FoundationModelsRanker/    # project slug (see below)
        01K3F.../                                      # routerId — Router's layout from here
            manifest.json
            sessions.jsonl
            01K3G.../transcript.jsonl
```

The **project slug** is the agent's working-directory absolute path with `/` → `-`
(the Claude Code projects convention): human-readable, collision-free in practice,
reversible enough for a browser UI to show real paths.

`transcripts.location` overrides: `project` puts the same layout under
`<project>/.<name>/transcripts/` (no slug segment; the harness then writes a
`.gitignore` of `*` + `!.gitignore` into the dotfolder, the Shelltool/CodeContext
convention) for users who want self-contained repos; an absolute path wins outright.

`TranscriptStore` also exposes the read side both frontends need:
`sessions(inProject:)` / `allProjects()` returning lightweight `Codable` summaries
(built from `sessions.jsonl` + `manifest.json`), and
`transcript(for sessionID:) -> [Transcript.Entry]` via Router's `TranscriptTree`
reconstruction. Session *restoration* into a live session already exists upstream
(`RoutedLLM.restoreSessionTree`) — the store just locates the directory to feed it.

The ownership boundary, stated plainly: **`TranscriptStore` never records and
never restores.** It owns exactly three things — the root location policy, the
project slug scheme, and lightweight browse summaries (read via Router's own
readers). Everything that gives a `transcript.jsonl` its meaning — writing
events, reconstructing entries, applying compaction checkpoints, rebuilding a
live session — is Router's, and the harness calls Router to do it.


### 6.1 Agent-instructions files — AGENTS.md via Extras' `AgentsMd`

*(Reframed 2026-07-21: these are **not memory files** — per
[agents.md](https://agents.md/), `AGENTS.md` is "a README for agents,"
context and instructions. Nothing here remembers anything across sessions.
The discovery walk itself is now Extras' fourth pillar, `AgentsMd` — Extras
plan §10 — because FoundationModelsAgents needs the identical walk for
sub-agent instructions; this layer just consumes it.)*

The single highest-leverage feature of the tools this product emulates is an
agent-instructions file read before doing anything. Resolution is **per
session, relative to its working directory** — never per process — so ACP's
`session/new(cwd)` and a multi-window app get the right context per
conversation automatically.

At session creation, this layer assembles two sources:

1. **User-level** — `~/.config/<name>/AGENTS.md` via
   `DotfolderStack.content("AGENTS.md")` (machine-wide; our extension — the
   spec itself has no home-directory concept), prepended most-general-first.
2. **Project-level** — `AgentsMd.documents(from: cwd)`: the walk from the
   repository root down to the session's cwd, reading at each directory the
   first of `AGENTS.md`, `AGENT.md` (the spec's migration alias),
   `CLAUDE.md` (ecosystem-compatibility alias), one file per directory,
   outermost-first so nearest-to-cwd lands last — the spec's "closest one
   takes precedence."

Assembly order (completing §4's picture): base prompt (builtin or
`instructions.replace`) → user-level file → project-level documents
(root → cwd) → config `instructions.append`. Each file is delimited by a
header naming its absolute path, so both the model and anyone reading the
session's `instructions` (the published-artifact contract, §4) can attribute
every line. Missing files are simply absent; a present-but-unreadable file is
a logged warning, not the hard error config files get — this is content, not
configuration. Each document renders through Extras' template engine
(untrusted, §4) before assembly, so partials and env vars work in AGENTS.md
exactly as they do in command templates.

The assembled text is read once at session creation, folded into the
`instructions` value handed to the harness constructor, and pinned for the
session's lifetime — a new session picks up edits. Instructions are never
folded by compaction (Router compaction plan §1.3 invariants), so this
context survives every fold by construction. The harness never knows any of
this happened; it just receives longer instructions.

### 6.2 Slash commands — one registry, three sources

Slash commands are a session-level noun: `/compact` acts on *this* session,
and a skill discovered in *this* repo becomes a command in *this* session
only. So the registry lives on `HarnessSession`, assembled at session
creation like tools and memory, and re-published when a source changes.

**The cross-package currency is Extras' `SlashCommand`**: `name` /
`description` / `argumentHint` plus a two-kind `Body` — `.prompt(template:)`
expands into an ordinary model turn; `.action` runs code and streams text,
never touching the model. Contributors implement `SlashCommandProviding`
(`commands(workingDirectory:)` + optional `commandUpdates` stream) against
the leaf, never the harness — the dependency diamond keeps arrows pointing
only downward.

Three sources, merged in precedence order (later wins on name collision,
logged; builtin names are reserved and never overridden):

1. **Builtins** — harness `.action` closures capturing the session:
   `/compact` (force compaction now), `/context` (fill, tokens, resolved
   context), `/memory` (print `Harness.instructions` with source headers —
   §4's published artifact, interactive), `/status` (session id, cwd,
   model/profile, transcript path), `/help`. Frontend verbs (`/quit`,
   clear-as-new) stay out — composer affordances, same rule as queueing.
2. **Linked providers** — `SlashCommandProviding` conformers registered by
   catalog roster entries (§7.1): the *code-backed* lane. Only linked Swift
   can construct `.action` — the trust boundary; in-process code is already
   trusted as tools. Skills is the flagship future conformer (one `.prompt`
   command per discovered skill, pushed via `commandUpdates` as files
   change). Day one ships the seam, not a conformer.
3. **Dotfolder templates** — the *data* lane: frontmatter markdown in
   `~/.config/<name>/commands/*.md` and `<project>/.<name>/commands/*.md`, rendered
   whole through Extras' Stencil engine (untrusted — §4) and parsed into
   `.prompt`-only commands. Data can never become `.action`: a broken or
   malicious template at worst yields a bad prompt under normal tool
   confinement. Layers user < project, like config. (MCP prompts are the
   reserved fourth source: `prompts/list` + `listChanged` feed this same
   registry when the MCP roster entry lands — finally consuming ACP's
   `mcpServers`.)

**Dispatch lives at the prompt owner** — this package's `prompt()` handler
for the wire, and the frontends' composers for direct consumption (the old
"dispatch lives in `run()`" died with the harness re-scope: the loop no
longer knows commands exist, and a `/compact` typed in an editor must never
reach the model as a prompt). A leading `/name` routes through the registry
*before* anything touches the session: `.prompt` expands (template +
arguments) into a normal recorded turn; `.action` streams output with **no
model turn and no transcript entries** beyond what the action itself records
(`/compact` its `CompactionSegment`; `/help` nothing). Unknown `/name`
errors with near-matches — never a model turn; frontends escape a literal
leading slash. Registry mechanics (merge, precedence, near-miss matching,
`commandUpdates` re-publication) are this package's; the vocabulary is
Extras'.

On every registry change: `HarnessState.availableCommands` updates (CLI
autocomplete, app palette) and the ACP conformance fires
`available_commands_update` (§9.1) — the protocol noun this registry peers
with.


## 7. Tools

### 7.1 The catalog — the well-marked follow-up location

`Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` is the single
place tools are registered — the well-known names for our well-known tools
(head decision): each linked package gets one reserved config section, and
adding a tool is a dependency plus one catalog line:

```swift
/// The harness tool catalog.
///
/// ══════════════════════════════════════════════════════════════════
///   ADD NEW TOOLS HERE — and only here.
///   1. Put the implementation in Tools/<Name>/.
///   2. Append its constructor to `builtin(context:)` below.
///   3. Add a row to the table in README.md § Tools.
///   Nothing else in the harness needs to change.
/// ══════════════════════════════════════════════════════════════════
public enum ToolCatalog {
    public static func builtin(context: ToolContext) -> [any FoundationModels.Tool]
}
```

`ToolContext` carries what every tool needs (working directory, the event-emitter for
`ObservedTool`, the flash handle) so tool constructors stay uniform. Frontends may
append their own tools: `Harness(..., extraTools: [any Tool])`.

Catalog entries are also where slash-command providers register (§6.2): an
entry may pair its tool with a `SlashCommandProviding` conformer (from
`FoundationModelsExtras`) and the catalog feeds it into the session's command
registry. The direction rule is absolute — tool packages conform to the
*leaf's* protocol; nothing outside this package ever names a harness type.


### 7.3 The tool roster (composed as each package ships)

Each tool is one catalog entry plus (usually) one dependency. Reserved config
section names keep the schema forward-compatible (§4):

| Tool | Source | Blocked on | Config section |
|---|---|---|---|
| `files` | `FoundationModelsFileTool` (**built**) — first builtin entry, in v1 | nothing | `files:` |
| `shell` | `FoundationModelsShelltool` (**built**) — second builtin entry, in v1 | nothing | `shell:` |
| code-context ops (`searchSymbol`, `callGraph`, `blastRadius`, …) | thin `Tool` shim over `CodeContext` — explicitly left to consumers | nothing; first follow-up | `codeContext:` |
| MCP servers | `MCPToolProvider` | nothing; needs config for server commands | `mcp:` |
| `runCode` | `MultiTool` (JS composition over the catalog) | nothing | `multitool:` |
| skills / sub-agents | FoundationModelsSkills / FoundationModelsAgents | those packages (plan-only) | `skills:` / `agents:` — Skills also contributes dynamic `/skill-name` slash commands via `SlashCommandProviding` (§6.2) |


## 9. Frontends: the shared-consumption contract

Three consumers share the harness: the Mac app, the CLI, and **any ACP client**
(Zed, editors — §9.1). The app and CLI are out of scope to *build* here, but every
contract is in scope to *prove*:

- Both construct **this package's composed agent** with the **same dotfolder
  name** — that single string is what makes config and transcripts shared.
  The name is chosen by the frontend, not baked into any layer below.
- The CLI is a thin ArgumentParser wrapper: parse args → construct agent → render the
  `HarnessEvent` stream to the terminal. `Examples/HarnessDemo` *is* this CLI in
  miniature and doubles as the living contract test; the production CLI likely grows
  in its own repo from a copy of it.
- The Mac app binds `HarnessState` and `ResolutionProgress` to SwiftUI and uses
  `TranscriptStore.allProjects()`/`sessions(inProject:)` for its history browser.
- **Sandboxing decision:** sharing `~/.config/<name>` and `$CWD/<anywhere>` is incompatible
  with the App Sandbox. Recommendation: the Mac app ships **non-sandboxed** (a
  developer tool operating on arbitrary repos — the norm for this product class; it
  can still be notarized and hardened-runtime). If sandboxing ever becomes mandatory,
  the fallback is security-scoped bookmarks per project plus moving the home layer to
  `~/Library/Application Support/<name>/` with the CLI honoring the same path — the
  `DotfolderStack` seam localizes that change. Decide before the app ships; nothing in
  the harness blocks on it.

### 9.1 ACP: this package's agent composes the harness

`HarnessACPAgent` — this package's `Agent` conformance — composes `Harness`/
`HarnessSession` with the config, roster, and command registry from §§4–7.
ACP is an **application protocol** — its nouns (cwd sessions, prompt turns,
visible tool calls, stop reasons, session management, available commands)
are owned across the stack this package assembles, and a wire protocol
attaches at the layer that owns its nouns (a language *server* speaks LSP; a
parser doesn't). The lower layers never pretend to be agents: the harness
stays a wire-free loop, `RoutedSession` stays Router's session surface,
`LanguageModelSession` stays Apple's conversation primitive.

**The wire layer is this package's first target** (`FoundationModelsACP`):
generated schema types (vendored v1.19.x), the `Agent`/`Client` role
protocols, the `*SideConnection` full-duplex runtime, ndJSON framing — zero
dependencies, spec'd in §9.2.

**Explicit peering — harness nouns ↔ ACP nouns.** The conformance
(`HarnessACPAgent`, in this package's agent target) is a
*translation, not a construction*: every ACP concept names its harness peer,
and anything with no peer is a capability switched off honestly, never faked.

| ACP noun | Harness peer |
|---|---|
| the agent behind the connection | `Harness` — `initialize` reports its capabilities: text prompts, session management on; the harness never issues `terminal/*` or `fs/*` in v1 (tools run in-process, below; terminals are a *client* capability the harness simply never exercises) |
| session (`sessionId`, cwd, `mcpServers`) | `HarnessSession` — `session/new(cwd)` ⇒ `harness.newSession(cwd:)`; project config layer, §6.1 memory, tool confinement, and transcript slug are already keyed off that cwd; `mcpServers` is accepted-and-ignored in v1 (logged, documented) |
| `session/prompt` (long-lived request) | `HarnessSession.run(prompt)` — one turn; the pending request resolves at turn end with a `StopReason` |
| `session/update` notification stream | the `HarnessEvent` stream, mapped 1:1: `textDelta` → `agent_message_chunk`, `reasoningDelta` → `agent_thought_chunk`, `toolCall(id:)` → `tool_call`, `toolStatus(id:)` → `tool_call_update` — `ToolCallID` *is* the wire `toolCallId` (§6) |
| `StopReason` | the turn's disposition: completed → `end_turn`, guardrail refusal → `refusal`, `cancel()` → `cancelled` |
| `available_commands_update` | the session's slash-command registry (§6.2) — published at session start and re-published whenever a source changes (skill discovered, template edited); invoked commands arrive as `session/prompt` text and dispatch inside `run()` like every frontend's |
| `session/cancel` (notification) | `HarnessSession.cancel()` — the still-open prompt request resolves with `cancelled`, possibly after final updates |
| `session/list` / `load` / `resume` / `delete` | `TranscriptStore.sessions(inProject:)` + Router restore. **Replay comes from Router's full recorded history** (the conversation the user actually had); **the live session is constructed from the newest compaction checkpoint** (the model's working transcript) — two different transcripts, deliberately. Restore reassembles the harness side (config layer, memory, confinement) from the cwd recorded at handle minting (§8) |
| `session/close` | `Harness` drops the `HarnessSession` from its bookkeeping — recording handle closed, transcript retained on disk (the v2 RFDs make this baseline alongside list/resume, below) |
| `authenticate` / `logout` | no peer — a local on-device agent has no auth; capability off, method-not-found, and the `authRequired` error (-32000) is never raised |
| session config options | no peer in v1 — capability off (may earn a peer later; typed config values are v2-baseline material) |
| session modes (`session/set_mode`) | never — deprecated wire-side in favor of `set_config_option`; the conformance answers method-not-found and no mode support is planned |
| `fs/*`, `terminal/*`, `session/request_permission` | no peer in v1 — tools run in-process (below) |

Because ACP turns go through `run()`, everything §6 owns works over ACP with
zero ACP-specific code: compaction (proactive and reactive), recording sync,
memory, confinement, the context meter. `HarnessState` has no peer — a
frontend affordance ACP clients replace with their own UI — and queueing stays
composer-owned (§6). (Name note: the inlined target declares the protocol-role
`Agent`; Harness-first naming means nothing else is named `Agent`, so
`HarnessACPAgent: Agent` reads unambiguously.)

Practical decisions:

- **The production CLI and the ACP agent are the same binary** — `<cli> acp` speaks
  ndJSON over stdio (stdout sacred, logs to stderr — §9.2's framing rules). One more
  reason the CLI stays thin: all three frontends are renderers over the same engine.
- **v1 supports multiple concurrent ACP sessions.** One-resident-profile
  constrains *loaded models*, not session count: `HarnessSession`s keyed by
  `sessionId`, each with its own cwd-derived config layer, memory,
  confinement, and slug; turns serialize at the model's `serialGate`;
  recording stays per-session via per-session handles (§8).
  **Profile-collision policy:** a project layer naming a different model than
  the resident profile logs a warning and keeps the resident model; the rest
  of the layer is honored. Gate waits are `Task`-cancellation-aware, so a
  queued session's `session/cancel` never outwaits another session's turn.
- **Tools stay in-process in v1 — an accepted, visible risk.** ACP routes file
  access through the client (`fs/*`, `session/request_permission`); ours hit
  the local filesystem directly — workable while agent and client share a
  machine, but unusual for an in-editor ACP agent, so recorded as an accepted
  risk (PathGuard/ShellPolicy confine the blast radius). The seam is
  `ToolContext`, which can later carry an ACP-backed filesystem/permission
  environment — a follow-up, gated on need.
- **stdout purity is tested, not assumed.** The `shell` tool runs subprocesses
  in-process while stdout must carry nothing but ACP frames; a gated integration
  test runs `<cli> acp`, executes a real shell-tool turn, and asserts every stdout
  byte parses as ndJSON (§10).

**Superseded: the `SessionProvider` design** — an external bridge driving the
inner bare session through a provider (factory + store hooks + `onTurnEnded`
sync). It failed on four counts, all symptoms of attaching an application
protocol at the model layer: a **stale session** after every compaction swap
(the session was handed over by value, once); **compaction never triggering**
on ACP turns (fill check and retry live in `run()`); a bolt-on turn-end
recording hook; and `session/load` **replaying the compacted transcript**
instead of the user's real history. All four dissolve with the agent-level
conformance; none of the provider machinery gets built.

Tailwind worth noting: the **ACP v2 RFDs** (active as of 2026-07-02) make
`session/list` / `resume` / `close` *baseline* and fold `session/load` into
`session/resume` with `replayFrom` cursors — i.e., the protocol is converging on
exactly the session model the peering table already provides (`TranscriptStore` +
Router's checkpoint-aware restore), so the conformance is an investment in the v2
direction, not v1-only plumbing.

### 9.2 The wire target — `FoundationModelsACP` spec

The wire-layer spec — home again after a round trip (planned standalone →
inlined into the harness → back here at rebirth); its bridge/`SessionProvider`
sections died in §9.1's Superseded note and are not reproduced.

**Provenance.** ACP's **Rust schema crate is the source of truth** — every
official SDK is generated from its emitted JSON Schema. There is **no official
Swift SDK**, and the three community ones (`aptove/swift-sdk`,
`wiedymi/swift-acp`, `rebornix/acp-swift-sdk`) are pre-1.0, hand-typed (so
they lag the schema), and partial — so we build our own, stealing their good
ideas: actor connection, `AsyncStream` for `session/update`, in-memory test
transport. License **Apache-2.0**, matching the spec and every reference SDK.
Data types are **generated** from the published schema
(`schema/v1/schema.json` + `meta.json`, from the `agentclientprotocol` org's
releases); connection, role protocols, and transport are **hand-written**,
porting the classic Rust async-trait design (rust-sdk v0.10.4: symmetric
`*SideConnection`s, oneshot + pending-map JSON-RPC engine), not the heavier
`Role`/`Builder` rewrite in runtime 1.0.0.

**Type-mapping rules (schema → Swift).** Idiomatic, not a transliteration:

- **Tagged unions** (`oneOf` + discriminator) → `enum` with associated values,
  hand-rolled `Codable` keyed on the discriminator.
- **Objects** → `struct` with explicit `CodingKeys` (wire is camelCase).
- **String enums** (`ToolKind`, `ToolCallStatus`, `StopReason`, …) →
  hand-rolled `Codable` routing unknown wire strings to `unknown(String)` — a
  newer peer's value can't crash decoding.
- **ID newtypes** (`SessionId`, `ToolCallId`, …) → distinct `RawRepresentable`
  structs, never bare `String`.
- **`_meta`/free-form fields** (`rawInput`, `rawOutput`, MCP env) →
  `JSONValue`; `_meta` round-trips uninterpreted.
- **Capability-gated optionals** — absence = unsupported. Negotiated surfaces
  decode defaults-on-error (a malformed capability degrades to "unsupported",
  never fails `initialize`); on encode, omit `nil`, never emit `null`.
- **`protocolVersion` is a wire integer**: a `UInt16` newtype encoding bare
  `1` (`.v1 = 1`, `.latest = .v1`), rejecting `"v1"`/`"1.0.0"`.
- **Versioning**: target v1; growth via capabilities + `_meta`; generated code
  checked in, regenerated on schema bump only.

**Core type analogs** (representative; the generator emits the full set):

```swift
public struct SessionId: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String }
public struct ToolCallId: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String }

// The streaming notification payload (discriminator: `sessionUpdate`)
public enum SessionUpdate: Codable, Sendable {
    case userMessageChunk(ContentBlock)
    case agentMessageChunk(ContentBlock)
    case agentThoughtChunk(ContentBlock)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case plan(Plan)
    case availableCommandsUpdate([AvailableCommand])
    case usageUpdate(UsageUpdate)
    case currentModeUpdate(SessionModeId)
}

public enum ToolCallStatus: Codable, Sendable, Hashable {
    case pending, inProgress, completed, failed
    case unknown(String)                    // forward-compat; hand-rolled Codable
}
public struct ToolCall: Codable, Sendable {
    public var toolCallId: ToolCallId
    public var title: String
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var content: [ToolCallContent]?
}
public struct ToolCallUpdate: Codable, Sendable {   // all optional → partial update
    public var toolCallId: ToolCallId
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var rawOutput: JSONValue?
}

public enum StopReason: Codable, Sendable { case endTurn, maxTokens, refusal, cancelled; case unknown(String) }

// JSON-RPC errors: standard codes + ACP's -32000 authRequired / -32002 resourceNotFound,
// structured `data`, never JSON smuggled through the message string.
public struct RequestError: Error, Codable, Sendable { public var code: Int; public var message: String; public var data: JSONValue? }

public enum JSONValue: Codable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
}
```

**Role protocols** (hand-written; implement `Agent` to be driven by an editor,
`Client` to drive an agent):

```swift
public protocol Agent: Sendable {
    func initialize(_ p: InitializeRequest) async throws -> InitializeResponse
    func newSession(_ p: NewSessionRequest) async throws -> NewSessionResponse
    func loadSession(_ p: LoadSessionRequest) async throws -> LoadSessionResponse   // optional cap
    func prompt(_ p: PromptRequest) async throws -> PromptResponse                  // returns StopReason
    func cancel(_ p: CancelNotification) async                                       // notification
    func authenticate(_ p: AuthenticateRequest) async throws -> AuthenticateResponse // optional
    func setSessionConfigOption(_ p: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse
    @available(*, deprecated, message: "Use setSessionConfigOption")
    func setSessionMode(_ p: SetSessionModeRequest) async throws -> SetSessionModeResponse
    // Session management — stabilized in the current schema
    func listSessions(_ p: ListSessionsRequest) async throws -> ListSessionsResponse   // optional
    func resumeSession(_ p: ResumeSessionRequest) async throws -> ResumeSessionResponse // optional
    func deleteSession(_ p: DeleteSessionRequest) async throws                          // optional
    func closeSession(_ p: CloseSessionRequest) async throws                            // optional
    func logout(_ p: LogoutRequest) async throws                                        // optional
}

public protocol Client: Sendable {
    func sessionUpdate(_ n: SessionNotification) async               // notification; the dominant traffic
    func requestPermission(_ p: RequestPermissionRequest) async throws -> RequestPermissionResponse
    func readTextFile(_ p: ReadTextFileRequest) async throws -> ReadTextFileResponse
    func writeTextFile(_ p: WriteTextFileRequest) async throws
    // Terminals — the client owns them; the agent drives them. Capability-gated.
    func createTerminal(_ p: CreateTerminalRequest) async throws -> CreateTerminalResponse
    func terminalOutput(_ p: TerminalOutputRequest) async throws -> TerminalOutputResponse
    func waitForTerminalExit(_ p: WaitForExitRequest) async throws -> WaitForExitResponse
    func killTerminal(_ p: KillTerminalRequest) async throws
    func releaseTerminal(_ p: ReleaseTerminalRequest) async throws
}
```

Method-name mapping is internal (`session/new` → `newSession`); optional
methods are capability-gated, unsupported calls return JSON-RPC
method-not-found. **Connections** are two symmetric objects over one byte
stream, each taking a **factory closure** so the handler can capture its own
connection for reverse calls:
`AgentSideConnection(stream:) { conn in HarnessACPAgent(conn, harness) }` /
`ClientSideConnection(stream:) { agent in MyClient(agent) }`. **Wire
invariants at the type boundary**: paths absolute, line numbers 1-based (an
`AbsolutePath` newtype makes violations decode-time errors); chunks correlate
by message id, tool calls by `toolCallId`
(`pending → in_progress → completed/failed`), and the API surfaces those ids —
consumers never infer ordering.

**Connection model — two concurrent streams, not request/response.** ACP is
full-duplex and notification-first: either peer sends requests and
notifications at any time, many in flight both directions. `session/prompt`
stays pending the whole turn while the agent fires `session/update`
notifications and issues reverse-direction requests concurrently; it resolves
only at turn end with a `StopReason` — the turn's content is the notification
stream, the response just the terminator. The client side surfaces per-session
`session/update` as an `AsyncStream<SessionUpdate>`; the agent side fires and
forgets. Implementation: one read loop per connection; correlation via
monotonic id + `[RequestID: CheckedContinuation]` inside the connection actor
(which also serializes writes); **each inbound request dispatches as its own
`Task`** — why a slow `session/prompt` can't head-of-line-block a
`session/cancel` or callback; long-lived requests are suspended continuations
that must never block the read loop. **Fail loud on disconnect** (a real
TS-SDK gap): on EOF/error, reject every pending continuation and finish the
streams; per-request timeouts; honor `Task` cancellation. **Tolerate
late/out-of-order notifications**: a `tool_call_update` may arrive after the
prompt response or a cancel — correlate to turn/session, drop or attribute
deliberately. **Framing**: ndJSON — one UTF-8 JSON object per line, **no
`Content-Length` headers** (not LSP; we own the codec); buffer partial lines,
tolerate escaped slashes, log-and-skip bad lines. **stdout is sacred — the #1
field failure**: nothing but ACP messages on stdout, logs to stderr; the
target exposes a logger and never prints (tested, §9.1/§10).

**Codegen — build-time, incremental, checked in.**

- **Vendored schema + routing manifest**: `schema/v1/schema.json` AND
  `meta.json` (canonical artifacts on the `agentclientprotocol` org's
  `schema-v*` releases) in `Schema/`; bumping ACP = dropping in a new pair.
- **Routing table generated from `meta.json`** (`x-side`/`x-method`), never
  hand-wired — structurally avoids the TS-SDK bug class (`setSessionModel`
  wired to `session/set_mode`). Unstable methods generate from
  `meta.unstable.json` into an `Unstable` namespace.
- **No-op unless the schema changed** (content-hash stamp in the output).
- **Generated code checked in** — consumers just compile source.
- **A SwiftPM command plugin** (`swift package generate-acp`) writes the
  files (command plugins may write to the package dir; build-tool plugins
  can't); CI runs it and **fails on any diff**.

Hand-written, never generated: transport, connections, role protocols,
`JSONValue`, the `unknown` fallbacks.

**Vendor schema v1.19.x** (checked 2026-07-14): request cancellation (v1.17)
and boolean session config options (v1.18) stable; ID naming unified
(regenerate, don't patch); elicitation still unstable. Keep the pipeline ready
to vendor a v2 schema behind a labeled unstable namespace when the RFDs
publish (§9.1 tailwind) — don't chase v2 into the stable surface.

**Wire-layer testing** (`FoundationModelsACPTests`, §10): ndJSON makes a
session trivially recordable — tee the byte stream and you have a replayable
script. `ReplayTransport` replays a recorded client→agent script against
golden `session/update` fixtures (framing, ordering, tool-call pairing, late
updates, `StopReason` — deterministic, no model); `InMemoryTransport` (paired
in-process `AsyncStream`s) wires a `Client` and `Agent` back-to-back with no
pipes. A captured run doubles as an eval case (§10.1).

**Open questions**: generator choice (custom SwiftSyntax vs off-the-shelf —
the checked-in pipeline tilts custom); which stable methods surface
first-class vs `Unstable` (terminals, `set_config_option`, `logout`, session
management are stable as of v1.19); how aggressively to track point releases.

### 10.1 Evaluations — `PythonCLIEvaluation` (end-to-end coding agent)

*(Moved here 2026-07-21 from the harness plan: this eval drives real `files`
+ `shell` tools, and no tool package may be referenced in the harness
package — the harness keeps a compaction-focused eval over sample tools
instead. This one belongs to the layer that composes the roster.)*

**`PythonCLIEvaluation` (files + shell, end to end).** Drives both core
tools through a real multi-turn build task, on Apple's Evaluations framework
(swift-testing native), gated on Apple silicon + real models + network:

1. **Subject**: `subject(from sample:)` creates a **fresh temp workspace** —
   the session's `workingDirectory` and the tools' confinement root — wires
   recording into a temp location, constructs the composed agent with real
   `files`/`shell` tools and the coding instructions, runs it to completion
   on the sample's prompt, and returns a result carrying the workspace path,
   the transcript, and run stats.
2. **Dataset**: `ArrayLoader` of `ModelSample`s — each prompt a variant of
   "build a small Python CLI" (`pyproject.toml`, at least one third-party
   package such as `click`, the CLI, pytest tests, a project-local venv,
   pytest green, then run it), with `expected` carrying the fixed
   input/output pair the finished CLI must satisfy. Start with 20–30
   hand-written samples per Apple's guidance; scale later with
   `SampleGenerator`.
3. **Quantitative `Evaluator`s — mechanical, re-verified outside the agent**
   (never trusting the transcript's claims), one `Metric` each, returning
   `.passing()`/`.failing()` with rationales: `PytestGreen` (the evaluator
   re-runs `pytest` in the venv itself, exit 0), `CLIRuns` (executes the CLI
   itself against `sample.expected`'s fixed input and checks the output),
   `FilesPresent` (expected files exist), and `ToolTraffic` (the transcript
   contains both `files` and `shell` tool calls).
4. **Aggregation and target**: `MetricsAggregator.computeMean` per metric;
   the `@Test` asserts mean pass rates against thresholds. Turn count,
   tool-call counts, and token usage ride along as scored values, keyed by
   the resolved model from `manifest.json`.

Isolation rules: everything happens inside the temp workspace — venv within
it, no system-Python mutation, no network beyond package install; the
workspace is deleted after grading (transcripts retained for failed runs).

