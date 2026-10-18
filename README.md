# NConsole

![The console playing Gem Hopper](docs/images/console.gif)

An 8-bit game console of our own, emulated inside Godot 4.7: the N8
processor, video with tiles, sprites and scrolling, a four-channel sound
chip, banked cartridges, an assembler, a machine-code debugger, and a 3D
model of the console that plays the games on its screen. Two games come
with it, written in N8 assembly: Snake and Gem Hopper, a side-scroller.

The console itself is a GDExtension in C++; the tools and views around it
are GDScript. All the details are in [addons/nconsole/README.md](addons/nconsole/README.md).

| Gem Hopper | Snake |
|---|---|
| ![Gem Hopper](docs/images/hopper.gif) | ![Snake](docs/images/snake.png) |

The debugger (F2): registers, the code at PC with your labels, and a
machine-code monitor, here stopped at a breakpoint in Gem Hopper.

![The debugger](docs/images/debugger.png)

## Using it in a project

Take `nconsole-<version>.zip` from the
[releases](https://github.com/uxerror/NConsole/releases) and unpack it into
the project: it holds `addons/nconsole/` with the native library built for
Linux, Windows and macOS. Then:

```gdscript
var console := NConsole.new()
console.insert(NCAssembler.load_cartridge("res://addons/nconsole/games/hopper.asm"))
console.set_pad(0, NConsole.BTN_RIGHT)
console.run_frame()                 # 1/60 s: picture in console.video.image, sound in console.sound
```

or put an `NConsoleScreen` (2D) or `NConsole3D` (the model) in a scene and
set its `cartridge_path`.

## Working on it

```sh
git clone --recursive https://github.com/uxerror/NConsole.git
cd NConsole/addons/nconsole/native
scons                                   # builds bin/ for this machine
cd ../../..
godot --headless --import
godot --headless --path . -s addons/nconsole/tests/run_tests.gd
godot --path .                          # the console on a table
```

## Regenerating the images

`tools/capture_media.gd` records everything in `docs/images` (a bot plays
Gem Hopper; see the script for the modes):

```sh
MODE=3d STATIC=1 FRAMES=240 OUT=/tmp/c3d godot --path . --resolution 960x540 -s tools/capture_media.gd
ffmpeg -framerate 20 -i /tmp/c3d/f%04d.png -vf "scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" docs/images/console.gif
MODE=2d FRAMES=240 OUT=/tmp/c2d godot --headless --path . -s tools/capture_media.gd
ffmpeg -framerate 20 -i /tmp/c2d/f%04d.png -vf "scale=480:360:flags=neighbor,split[a][b];[a]palettegen=max_colors=32[p];[b][p]paletteuse=dither=none" docs/images/hopper.gif
MODE=debugger OUT=/tmp/dbg godot --path . --resolution 1280x720 -s tools/capture_media.gd
```

## Continuous integration

`.github/workflows/ci.yml` builds the extension for Linux (x86_64),
Windows (x86_64) and macOS (universal), debug and release, and runs the
tests on Linux with Godot 4.7.2. Pushing a tag `v*` also publishes a
release with the addon ready to unpack.
