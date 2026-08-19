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

1. Extracts `library.swf` from `Dungeon-Rampage-Decompiled/extensions/FRESteamWorks.ane`
2. Decompiles it with FFDec into a temporary folder (the ANE ActionScript is not part of the game SWF)
3. Runs [ax4](https://github.com/Tutez64/ax4) with `edits/conversion/config.json`
4. Moves `com.amanitadesign` to `src-steam/` (C++ classpath only)

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
- `DungeonBustersProject`: add `stage.align = "";`

Needed for C++ target (these changes don't seem to make any difference in AIR):
- `MovieClipCutsceneRenderer`: delete soundTransform lines 165;170
- `MainPanel`: delete "Security.showSettings(...)" line 1160 (it doesn't do anything in AIR, it's only for Flash)
- `CommandLine`: delete `setPropertyIsEnumerable` line 208 (not available in OpenFL, possible to implement but not urgent)

Lastly, you can apply patches from ./patches
