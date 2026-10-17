# c1lut

Capture One styles → .cube LUTs for cameras and color grading.

c1lut turns your Capture One styles into 3D LUTs, so the look you edit with in Capture One can be
used in the camera, for example as a Lumix **Real Time LUT** on the S5II, or in DaVinci Resolve.
It is a small Swift tool plus a Capture One Scripts-menu entry. It uses only what ships with
macOS and Capture One: nothing else to install.

## How it works

Capture One can't export LUTs, but it can render any image with a style. c1lut gives it an image
that holds every color a LUT needs, then reads the result back:

1. **Grid.** c1lut makes a 16-bit TIFF of 33 × 33 × 33 color patches. For V-Log targets each
   patch first goes through Panasonic's V-Log → V-709 LUT, so the image looks the way the camera
   would show it before your look is applied.
2. **Render.** In a Capture One session of its own, c1lut applies the style to that image and
   exports it with a full-size sRGB TIFF recipe.
3. **LUT.** c1lut reads each patch back and writes a `.cube`: *V-Log in → your look out*.

Before the first style, c1lut renders the grid once without a style and checks it comes back
unchanged, so Capture One's export can't silently change your LUTs.

## What carries over

A LUT changes each color on its own, without looking at neighbouring pixels. So:

| Carries over | Can't be part of a LUT (c1lut sets these to 0 and tells you) |
|---|---|
| Curves, Levels, Exposure, Contrast, Brightness, Saturation | Clarity, Structure, Dehaze |
| Color Editor, Color Balance, Black & White | HDR Highlight and Shadow |
| White balance shifts | Sharpening, Noise Reduction, Film Grain, Moiré, Vignetting |
| Full-image ("filled") layers | Layers with drawn or AI masks (removed) |

The look will be close to Capture One but not identical: in Capture One your style sits on
Capture One's own camera profile, in the camera it sits on Panasonic's V-Log → V-709 conversion.
Shoot a test and compare before relying on a LUT.

## Requirements

- macOS 13 or later, on an Apple Silicon or Intel Mac
- Capture One Pro 16 (processing from scripts needs Pro)
- For V-Log targets: Panasonic's **V-Log to V-709** LUT. The installer downloads it from
  Panasonic for you (see below).

## Install

Open Terminal and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/andriiryzhkov/c1lut/HEAD/install.sh | sh
```

This downloads the latest release, adds **Scripts › Export Styles as LUTs** to Capture One and
fetches Panasonic's V-Log to V-709 LUT. If Capture One doesn't show the menu entry, choose
Scripts › Update Scripts Menu or restart Capture One. Run the same command again to update.

Everything goes into `~/Library/Application Support/c1lut`, plus the Scripts-menu entry in
`~/Library/Scripts/Capture One Scripts`. Nothing needs administrator rights.

To build from source instead, you need Swift (Xcode or `xcode-select --install`):

```bash
git clone https://github.com/andriiryzhkov/c1lut.git && cd c1lut && ./install.sh
```

## First run

1. In Capture One choose **File › New Session…**, name it `c1lut` and save it anywhere, for
   example in Documents. c1lut works only in this session, so your catalogs stay untouched.
2. Choose **Scripts › Export Styles as LUTs**, pick a target and your styles.
3. Point c1lut at the `c1lut` session file (`c1lut.cosessiondb`). It remembers it.
4. macOS asks once whether the script may control Capture One. Allow it.

c1lut then opens its session, renders each style and shows a summary. LUTs are saved in
`~/Documents/c1lut/<target>/`.

## Panasonic's V-Log to V-709 LUT

V-Log LUTs start from Panasonic's own V-Log → V-709 conversion. c1lut doesn't include that
file: it's Panasonic's. Instead it's downloaded from
[Panasonic's LUT page](https://eww.pass.panasonic.co.jp/pro-av/support/content/download/EN/ep2main/lut_e.htm)
(`VLog_to_V709_forV35_EN.zip`) on your Mac, just as if you had clicked Download there, and
checked to really be a V-Log → Rec.709 conversion before it's used.

- The installer downloads it. If that fails, for example offline, the Scripts-menu entry offers
  **Download from Panasonic** or **Choose File…** the first time you export for a V-Log target.
- To download it again: `c1lut setup --download-vlog-base`.
- To use a copy you downloaded yourself: unzip it and run
  `c1lut setup --vlog-base VLog_to_V709_forV35_ver100.cube`.
- If Panasonic moves the file, point c1lut at the new address with
  `C1LUT_VLOG_BASE_URL=<url> c1lut setup --download-vlog-base`.

Panasonic's file (made for VARICAM) writes video-range output: V-Log black comes out at code 64,
not 0. Lumix cameras want full-range LUTs, and Capture One shows images in full range, so c1lut
converts it: code 64 becomes black, 940 becomes white, and the little headroom above white is
clipped.

## Targets

| Target | Input → output | Points | File names |
|---|---|---|---|
| `lumix` | V-Log → Rec.709 | 33 | Up to 8 letters and digits, e.g. `PORTRAIT.cube` |
| `vlog` | V-Log → Rec.709, e.g. for DaVinci Resolve | 33 | The style name |
| `rec709` | Rec.709 → Rec.709, e.g. a Resolve timeline | 33 | The style name |

## Loading LUTs on a Lumix camera

1. Copy the `.cube` files to the top folder of the memory card. When a card with a `DCIM`
   folder is mounted, c1lut offers to do this for you.
2. On the camera, open **LUT Library**, pick a slot and load the file.
3. Set **Photo Style** to **Real Time LUT** and choose your LUT.
4. Expose for V-Log as usual. JPEGs and video get the look; RAW files stay untouched.

To check the starting point on your camera, make a LUT without any style and compare it with
the camera's built-in `Vlog_709` LUT. The two should look the same:

```bash
c1lut build "$(c1lut grid)" --name Neutral
```

## Command line

The helper can do everything the Scripts-menu entry does. To call it by name, link it into a
folder on your `PATH`, for example:

```bash
ln -s ~/Library/Application\ Support/c1lut/bin/c1lut /usr/local/bin/c1lut
```

```bash
c1lut styles
```

```bash
c1lut export --target lumix "Portrait Warm" "Street B&W"
```

To preview a LUT, apply it to a V-Log JPEG from the camera and compare it with the same raw
file edited in Capture One:

```bash
c1lut apply ~/Documents/c1lut/lumix/PORTRAIT.cube P1000123.JPG preview.jpg
```

`c1lut help` lists the lower-level commands (`grid`, `check`, `build`, `setup`, `targets`,
`path`, `install`, `uninstall`).

## Troubleshooting

- **"Capture One's render without a style differs from the grid"**: the `c1lut` process recipe
  in the c1lut session must export sRGB TIFFs at 100% with no output sharpening. c1lut sets this
  up itself; if you changed it, fix it or delete the recipe and run again.
- **"Neighbouring colors bled into each other"**: a local adjustment survived, usually from a
  style setting c1lut doesn't know about. The LUT may look noisy.
- **Nothing happens after choosing styles**: see `~/Library/Application Support/c1lut/export.log`.

## Uninstall

```bash
~/Library/Application\ Support/c1lut/bin/c1lut uninstall
```

This removes c1lut and its Scripts-menu entry. Your LUTs in `~/Documents/c1lut` and the `c1lut`
Capture One session stay; delete them yourself if you like.

## Development

```bash
swift test
```

- `Sources/C1LUTCore` handles `.cube` files, the grid and images. It's tested with a simulated
  style in place of Capture One.
- `Sources/c1lut` is the command-line tool. `Scripts/` holds the AppleScripts that drive Capture
  One; they're embedded in the binary, and `c1lut install` compiles them on the user's Mac
  (compiling needs Capture One's scripting dictionary).
- `scripts/build-release.sh` builds one binary for Apple Silicon and Intel into
  `dist/c1lut-macos.zip`.

### Releasing

Push a version tag. The Release workflow tests, builds and publishes `c1lut-macos.zip` as a
GitHub Release, which is what `install.sh` downloads:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Releases aren't signed with an Apple Developer ID. That's fine for the Terminal install, because
files downloaded with `curl` aren't checked by Gatekeeper. If you download the zip with a browser
instead, macOS blocks the program until you allow it in System Settings › Privacy & Security.

## License

MIT
