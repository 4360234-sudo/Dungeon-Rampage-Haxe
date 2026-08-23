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

Run the **Convert from AS3** IntelliJ configuration (or execute `./edits/conversion/convert.cmd` from this repository).

The script:

1. Copies `FRESteamWorks.ane` into `extensions/` and unpacks it for ADL
2. Extracts `library.swf` from that ANE
3. Decompiles it with FFDec into a temporary folder (the ANE ActionScript is not part of the game SWF)
4. Runs [ax4](https://github.com/Tutez64/ax4) with `edits/conversion/config.json`
5. Moves `com.amanitadesign` to `src-steam/` (C++ classpath only)

Useful options: `--prepare-only`, `--keep-tmp`, `--build-ax4`.
Overrides: `--ax4` / `AX4_DIR`, `--decompiled` / `DECOMPILED_DIR`, `--ffdec` / `FFDEC_HOME`, `--air-sdk` / `AIR_SDK`, `--ane`.

## After conversion

Copy `edits/src` over `src/` and `edits/src-steam` over `src-steam/` (`SwfAsset.hx` and the SteamWrap `FRESteamWorks.hx` replace generated files; the `openfl/` files are new).

Export the fonts using FFDec:

```bash
haxe tools/ffdec_fonts/export_swf_fonts.hxml
```

In `Db_UI_skip_button_swf.hx` and `Loading_screen_swf.hx`:
- Add `import brain.assetRepository.SwfAsset;` at the top
- Add this at the end of the constructor (adapt the font ID and file name):
    ```Haxe
    #if cpp
    SwfAsset.applyExportedFontById(this,"assets",27,"Loading_screen_swf");
    #end
    ```

These changes that can be done in either the AS3 or Haxe code:

Needed for AIR target:
- `PlayEffectTimelineAction` & `PlayEffectAttackTimelineAction`: replace the last three `= ""` by `= null ` in constructors

Lastly, you can apply patches from ./patches
