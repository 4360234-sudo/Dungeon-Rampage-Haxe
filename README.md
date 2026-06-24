<p align="center">
  <img src="icon.jpg" width="96" alt="Dungeon Rampage Haxe" />
</p>
<h1 align="center">Dungeon Rampage Haxe</h1>

<p align="center">
A native Windows, Linux, and macOS version of Dungeon Rampage.
Built to run smoother than the official AIR version, at 120 FPS instead of 24 FPS.
</p>

## Install and play

The recommended way to play DRH is
[DRH Launcher](https://github.com/Tutez64/DRH-Launcher), which handles DRH installation,
updates, repairs, and launch for you.

DRH Launcher also provides additional features such as launch option presets,
custom launch arguments, session history with logs and playtime, release history,
and more.

See the [DRH Launcher README](https://github.com/Tutez64/DRH-Launcher#readme)
for downloads and installation instructions.

You need to own the official
[Dungeon Rampage](https://store.steampowered.com/app/3053950/Dungeon_Rampage/)
on Steam and keep Steam open while playing. Otherwise, DRH cannot connect to the official servers.

## Why use DRH?

The official game can run poorly and suffer from input delay issues.
DRH runs at 120 FPS instead of the official game's 24 FPS, usually provides much better
performance, especially in **Quality** mode, and avoids the delay issue.

Like the official game, restarting before each new party is recommended because performance can degrade over time.

## Community

Join the [Discord server](https://discord.gg/VvWbNspZrQ) to discuss DRH and DRH Launcher,
get update notifications, and see occasional previews.

## Technical overview

DRH is a port of Dungeon Rampage from AS3/AIR to Haxe. It uses
[OpenFL](https://www.openfl.org/), a graphical library that reimplements Flash/AIR APIs
with native targets and modern tooling.

This project required months of work, most of it in the following open-source projects:

- [ax4](https://github.com/Tutez64/ax4), my AS3 to Haxe converter based on ax3.
- [OpenFL](https://github.com/Tutez64/openfl), [SWF](https://github.com/Tutez64/swf), [Lime](https://github.com/Tutez64/lime), and [hxcpp](https://github.com/Tutez64/hxcpp).
- [SteamWrap](https://github.com/Tutez64/SteamWrap), used to replace the Steam ANE.

## Build from source

The project depends on forked versions of OpenFL, Lime, SWF, hxcpp, and SteamWrap,
which are included as Git submodules.

### Requirements

- [Haxe](https://haxe.org/)
- A C++ toolchain supported by hxcpp
  - Windows: install the [Build Tools for Visual Studio](https://visualstudio.microsoft.com/downloads) (tick `Desktop development with C++`)

Install the regular haxelib dependencies:

```bash
haxelib install format
haxelib install hxp
```

### Clone the repository

```bash
git clone --recurse-submodules https://github.com/Tutez64/Dungeon-Rampage-Haxe
cd Dungeon-Rampage-Haxe
```

If you cloned without `--recurse-submodules`, initialize the submodules afterwards:

```bash
git submodule update --init --recursive
```

### Configure local development libraries

The project file references the submodules directly, but registering them with haxelib
is useful for commands such as `haxelib run openfl` and for rebuilding tools:

```bash
haxelib dev lime submodules/lime
haxelib dev openfl submodules/openfl
haxelib dev swf submodules/swf
haxelib dev steamwrap submodules/SteamWrap
haxelib dev hxcpp submodules/hxcpp
```

### Rebuild helper tools

```bash
haxelib run lime rebuild cpp -debug
haxelib run lime rebuild tools
haxelib run lime rebuild hxcpp
haxelib run lime rebuild swf
```

SteamWrap:

```bash
cd submodules/SteamWrap
./setup.sh # .bat on Windows
./build # .bat on Windows
cd ../..
```

### Build the game

From the repository root:

```bash
haxelib run openfl build project.xml cpp
```

For a debug build:

```bash
haxelib run openfl build project.xml cpp -debug
```

Replace `build` with `test` if you want the game to launch automatically after compiling.
