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

A **conversion** is one ax4 run against one official Steam build. It creates a pair of branches with the same suffix:

```text
converted/YYYY-MM-DD-b<BuildID>-<reasons>
edits/YYYY-MM-DD-b<BuildID>-<reasons>
```

`converted/X` is the raw, immutable ax4 output. `edits/X` is that output plus one commit per patch. `master` copies the resulting `src/`, `src-steam/`, and stamp.

`converted/latest` and `edits/latest` point at the current pair.

### Naming

BuildID is the `buildid` key in `steamapps/appmanifest_3053950.acf` of the install that was decompiled.

Reasons, in this order, joined with `+` (at least one is required):

| Token | Meaning |
|-------|---------|
| `dr` | Official update (BuildID ≠ `converted/latest`) |
| `jpexs` | Decompiler changed |
| `ax4` | Converter changed |

Same day, same BuildID, same reasons: suffix `-2`, `-3`.

```text
converted/2026-08-24-b20318421-dr
converted/2026-09-10-b20318421-ax4
edits/2026-09-12-b20318421-dr+jpexs+ax4
```

### Stamp

`edits/conversion/stamp` is written on the convert commit and imported with `src/` so `master` still records the conversion:

```text
branch=2026-08-24-b20318421-dr+ax4
date=2026-08-24
buildid=20318421
reasons=dr+ax4
jpexs=<sha>
ax4=<sha>
```

### Workflow

The polyglot script `./edits/conversion/refresh.cmd` (Bash + PowerShell) drives the git steps. Conflicts, squash, and commit order stay manual.

**Later conversion** (a `converted/latest` already exists):

```bash
./edits/conversion/refresh.cmd start --buildid BUILDID --reasons dr+ax4
# inspect src/, then:
./edits/conversion/refresh.cmd rebase
# on conflict: fix, then ./edits/conversion/refresh.cmd continue
# to rebuild the stack in a chosen order instead of rebase:
# ./edits/conversion/refresh.cmd replay <sha> <sha> ...
./edits/conversion/refresh.cmd import
```

`start` branches from `converted/latest`, runs `convert.cmd`, writes the stamp, and commits. Extra convert flags go after `--`. `--skip-convert` if ax4 already ran on this worktree.

`rebase` replays `edits/latest` onto the new `converted/` branch, names `edits/…` to match, and updates both `latest` pointers.

`import` copies `src/`, `src-steam/`, and the stamp from `edits/latest` onto `master`.

`git range-diff converted/X..edits/X converted/Y..edits/Y` compares two stacks after a rebase.

**First pair** (`converted/latest` does not exist yet): `start` converts from the current HEAD, then creates `edits/…` at that commit and points `latest`. Rebuild the stack on `edits/…` (order below) before `import`.

**Between conversions:** append commits on the current `edits/X`, then `import`. No new pair.

A small official update without ax4 is also a commit on the current `edits/X` (debt until the next real convert; the branch name still has the previous BuildID).

`src/` that must survive the next rebase is committed on `edits/X`. Project files, submodules, and tools stay on `master`. Releases are tagged on `master`.

### Edits stack

`git log converted/latest..edits/latest` is the source of truth. One commit per logical change, ordered by how necessary it is:

1. **AIR** — required for the AIR target
2. **C++** — required for native
3. **Bug fixes** — native often aborts where AIR continues
4. **Fonts** — wrong glyphs, still playable (`haxe edits/ffdec_fonts/export_swf_fonts.hxml` when SWFs change)
5. **Features** — neither required to run nor for DR parity

`edits/patches/` and the overlays in `edits/src/` / `edits/src-steam/` are leftovers from applying diffs onto `master`; drop them once the first pair exists. Optional crash repros live in `tools/debug/`, off this stack.

Font export is Haxe (Lime XML + FFDec). `convert.cmd` / `refresh.cmd` are shell (CLIs and git).
