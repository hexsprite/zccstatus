# zccstatus — cyberpunk powerline status line for Claude Code

Date: 2026-08-19
Status: approved, v1 in implementation

## Purpose

Claude Code renders a status line by running a command and printing its stdout.
`zccstatus` is that command. It is a single static Zig binary. It reads the
status JSON on stdin, writes one ANSI line to stdout, and exits.

The current setup runs `bunx -y ccstatusline@latest`. That starts a Node process
on every render. A static binary removes the process startup cost.

## Output

```
 Opus 5   112k/1M ▓▓░░░░░░ 11%   zccstatus   main  +156/-23  $0.42   58m
```

Segment order, left to right: model, context, working directory, git branch,
lines changed, session cost, cache countdown.

The cache countdown is last. It is the most volatile value, and the right edge
is where the eye rests.

## Data sources

Claude Code sends this JSON on stdin:

- `model.display_name`, `model.id`
- `workspace.current_dir`, `cwd`
- `cost.total_cost_usd`, `cost.total_lines_added`, `cost.total_lines_removed`
- `transcript_path`
- `exceeds_200k_tokens`

Token counts are **not** in the payload. The program reads them from the
transcript JSONL named by `transcript_path`.

### Context tokens

Read the last 256 KB of the transcript. Seek from the end. Never load the whole
file. Walk the lines backward. Stop at the first record where `type` is
`assistant` and `message.usage` exists.

Context used is `input_tokens + cache_read_input_tokens +
cache_creation_input_tokens`.

**Skip records with `isSidechain: true`.** Subagent messages are written to the
same file. Their token counts are the subagent's context, not the main one. If
you do not skip them, the bar reports the wrong number whenever a subagent runs.

If the tail holds no usable record, widen the read to 1 MB once. If that also
fails, show `--`.

### Context maximum

The payload does not carry the window size. Infer it from `model.id`:

- an id that contains `[1m]` means 1,000,000
- every other id means 200,000

`exceeds_200k_tokens` is a sanity check. An unknown id falls back to 200,000, so
the bar is pessimistic instead of flattering.

### Cache countdown

The countdown is `ttl - (now - timestamp of the last assistant message)`.

The TTL flavor comes from `message.usage.cache_creation`:

- `ephemeral_1h_input_tokens` above zero means a 1 hour TTL
- `ephemeral_5m_input_tokens` above zero means a 5 minute TTL

A turn that only reads cache has both fields at zero. In that case scan further
back for the most recent turn that created cache, and use its flavor. If no turn
in the tail created cache, use 5 minutes.

Below 60 seconds remaining, the segment turns to the theme's critical color.

## Git branch

No subprocess. Walk up from the working directory to find `.git`.

- `.git` as a directory: read `.git/HEAD`
- `.git` as a file: read the path after `gitdir:` (this is a worktree)
- `HEAD` that starts with `ref: refs/heads/`: the branch is the rest
- any other `HEAD`: the repository is detached, show the first 7 characters

A branch longer than 20 characters is clipped with an ellipsis. Outside a
repository, the segment is dropped.

## Themes

Three palettes, selected by `--theme <name>` or the `ZCC_THEME` environment
variable. The default is `neon`.

- `neon` — hot magenta, electric cyan, deep indigo
- `blade` — amber, teal, charcoal
- `acid` — terminal green, hot pink, black

A theme is a comptime table of RGB triples. Adding a fourth is a data change.

## Rendering

True color escapes, `\x1b[38;2;r;g;bm` for foreground and `\x1b[48;2;r;g;bm` for
background.

A powerline separator is drawn with the foreground of the segment that ends and
the background of the segment that starts. The final separator uses the default
background.

The context gauge is eight block cells. It fills as the window fills. Its color
moves through the theme's ok, warn, and critical colors.

## Width

Claude Code does not send the terminal width, and stdout is a pipe, so there is
no ioctl to ask. The bar keeps itself near 95 characters instead:

- the directory segment shows only the last path component
- the branch clips at 20 characters

## Failure behavior

A status line that crashes wedges the display, and the only debugging window is
one line tall. So:

- a segment that cannot read its data renders a placeholder or is dropped
- malformed stdin produces a minimal fallback bar
- the exit code is always 0

## Testing

`now` is passed in as a parameter. It is never read from the clock inside the
render path. This keeps the countdown math deterministic.

- fixture JSONL for the transcript scanner, including a case poisoned with
  sidechain records
- fixture directories for the git walker, covering a normal repository, a
  worktree, and a detached HEAD
- exact string tests for separator chaining
- number and duration formatting

## Build

Zig 0.16.0 from Homebrew. `build.zig` pins the version so a bump fails loudly.

```
zig build -Doptimize=ReleaseFast
```

The binary installs to `~/.local/bin/zccstatus`.
