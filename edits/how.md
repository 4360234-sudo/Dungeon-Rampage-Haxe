## Decompile

See [Dungeon Rampage Decompiled](https://github.com/Tutez64/Dungeon-Rampage-Decompiled).

## Convert to Haxe

Recommended layout:

```text
ax4/
Dungeon-Rampage-Decompiled/
Dungeon-Rampage-Haxe/
jpexs-decompiler/   # optional; FFDEC_HOME or PATH also work
```

Run the **Convert from AS3** IntelliJ configuration (or `./edits/conversion/convert.cmd`).

The script:

1. Copies `FRESteamWorks.ane` into `extensions/` and unpacks it for ADL
2. Extracts `library.swf` from that ANE
3. Decompiles it with FFDec into a temporary folder (the ANE ActionScript is not part of the game SWF)
4. Runs [ax4](https://github.com/Tutez64/ax4) with `edits/conversion/config.json`
5. Moves `com.amanitadesign` to `src-steam/` (C++ classpath only)

Useful options: `--prepare-only`, `--keep-tmp`, `--build-ax4`.
Overrides: `--ax4` / `AX4_DIR`, `--decompiled` / `DECOMPILED_DIR`, `--ffdec` / `FFDEC_HOME`, `--air-sdk` / `AIR_SDK`, `--ane`.

## After conversion

A **conversion** is one ax4 run against one official Steam build. It creates a pair of **src-only** orphan branches with the same suffix:

```text
converted/YYYY-MM-DD-b<BuildID>-<reasons>
edits/YYYY-MM-DD-b<BuildID>-<reasons>
```

Those branches contain only `src/`, `src-steam/`, and `edits/conversion/stamp`. Stay on `master` (or another full-tree branch) for compilation. `converted/X` is the raw, immutable ax4 output. `edits/X` is that output plus one commit per logical change. `master` copies the resulting `src/`, `src-steam/`, and stamp.

`converted/latest` and `edits/latest` point at the current pair.

`compat/` is ax4’s runtime. A converter change that only touches `compat/` is a `master` commit, not a reason to open a new pair.

### Naming

BuildID comes from `Dungeon-Rampage-Decompiled/tools/official.buildid`. `--buildid` overrides it.

Reasons, in this order, joined with `+` (at least one is required):

| Token | Meaning |
|-------|---------|
| `dr` | Official update (BuildID ≠ `converted/latest`) |
| `jpexs` | Decompiler changed the generated `src/` |
| `ax4` | Converter changed the generated `src/` |

Same day, same BuildID, same reasons: suffix `-2`, `-3`.

```text
converted/2026-08-24-b20318421-dr
converted/2026-09-10-b20318421-ax4
edits/2026-09-12-b20318421-dr+jpexs+ax4
```

### Stamp

`edits/conversion/stamp` is written on the convert commit and imported with `src/` so `master` still records the conversion (which ax4 produced this `src/`, not which ax4 is used to compile):

```text
branch=2026-08-24-b20318421-dr+ax4
date=2026-08-24
buildid=20318421
reasons=dr+ax4
jpexs=<sha>
ax4=<sha>
```

### Workflow

The polyglot script `./edits/conversion/refresh.cmd` (Bash + PowerShell) drives the git steps. Replay and squash run in a throwaway worktree so the main checkout stays full-tree.

**Later conversion** (a `converted/latest` already exists):

```bash
./edits/conversion/refresh.cmd start --reasons dr+ax4
# inspect src/ in this worktree, then:
./edits/conversion/refresh.cmd rebase
# on conflict: fix in the refresh worktree, then ./edits/conversion/refresh.cmd continue
# to rebuild the stack in a chosen order instead of rebase:
# ./edits/conversion/refresh.cmd replay <sha> <sha> ...
./edits/conversion/refresh.cmd import
```

`start` runs `convert.cmd` here, writes the stamp, and creates an orphan `converted/…` commit. Extra convert flags go after `--`. `--skip-convert` if ax4 already ran on this worktree.

`rebase` replays `edits/latest` onto the new `converted/` branch (folding `Squash-with:` trailers), names `edits/…` to match, updates both `latest` pointers, and restores `src/` in this worktree.

`commit -m "…"` appends a src-only commit on `edits/latest` from the worktree. `squash` folds trailers on the current pair without a new conversion.

`import` copies `src/`, `src-steam/`, and the stamp from `edits/latest` onto `master`.

`git range-diff converted/X..edits/X converted/Y..edits/Y` compares two stacks after a rebase.

**First pair** (`converted/latest` does not exist yet): `start` converts, creates `edits/…` at that commit, and points `latest`. Stack with `refresh commit` (order below) before `import`.

**Between conversions:** `refresh commit` on the current `edits/X`, then `import`. No new pair.

A small official update without ax4 is also a `refresh commit` on the current `edits/X` (debt until the next real convert; the branch name still has the previous BuildID).

`src/` that must survive the next rebase is committed on `edits/X`. Project files, submodules, `compat/`, extensions, and tools stay on `master`. Releases are tagged on `master`.

### Squash-with

A line that is exactly `Squash-with: <sha>` (7–40 hex chars, nothing else on the line) folds that commit into the referenced one. The sha must be in the same `converted/latest..edits/latest` range (or the `replay` list).

`rebase` / `replay` / `squash` apply the fold. Several commits may point at the same target; chains are one group. The group is emitted at the oldest member’s place (later members are skipped when their turn comes).

Combined message: oldest title is the commit title; its body is first. Each later commit is appended as its title, then its body. `Squash-with:` lines are dropped; `Co-authored-by:` lines are collected at the end.

### Edits stack

`git log converted/latest..edits/latest` is the source of truth. One commit per logical change. Titles start with a prefix so the category is visible and `rebase` can restore this order (`air` → `cpp` → `bug` → `font` → `feat`, stable inside each):

| Prefix | Meaning |
|--------|---------|
| `air:` | Required for the AIR target |
| `cpp:` | Required for native |
| `bug:` | Native often aborts where AIR continues |
| `font:` | Wrong glyphs, still playable (`haxe edits/ffdec_fonts/export_swf_fonts.hxml` when SWFs change) |
| `feat:` | Neither required to run nor for DR parity |

Optional crash repros live in `tools/debug/`, off this stack.

Font export is Haxe (Lime XML + FFDec). `convert.cmd` / `refresh.cmd` are shell (CLIs and git).
