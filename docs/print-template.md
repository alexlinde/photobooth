# Print strip template

## What gets printed

The printer is a Canon SELPHY CP910 loaded with 100 x 148 mm (4x6 / postcard) paper, printed borderless. Each sheet holds two identical strips side by side. You cut the sheet in half down the middle by hand. You design ONE strip; the app places your artwork twice.

## Geometry (one strip, origin top-left, mm)

| Item | Value |
|---|---|
| Strip size | 50 x 148 mm (portrait) |
| Photo windows | x = 4, width 42, height 28 (3:2) |
| Window 1 / 2 / 3 | y = 4 / 35 / 66 (3 mm gaps) |
| Caption / artwork area | y = 94 to 148 (50 x 54 mm) |
| Safe zone | keep text and key content at least 4 mm inside all four edges |
| Bleed | backgrounds must reach the very edge of the artboard; borderless printing can trim 1-2 mm |

The app draws the photos on top of your artwork in the windows, so anything under a window is hidden. Leave them plain.

## Steps in Illustrator

1. Open `templates/print-strip-template.svg`. The artboard is 50 x 148 mm.
2. Design on the `Artwork` layer. It starts with a white background rectangle; replace or recolour it, but keep it covering the full artboard.
3. The caption text ("Alex & Christina's 25 Years of Awesome") goes in the lower area. You can use Illustrator's generative AI (Text to Vector) on the Artwork layer for decoration.
4. Hide the `Guides - hide before export` layer (windows, magenta safe-zone box, labels).
5. File > Export > Export As..., format PNG. Tick "Use Artboards". In the PNG options set Resolution 300 ppi (or Other: 600 ppi), Background Color White (Transparent also works; the app composites onto white), Anti-aliasing Art Optimized.

Any resolution is fine as long as the aspect ratio is 50:148. The app scales the image to 600 x 1776 px (12 px/mm). 300 ppi gives about 591 x 1748.

`templates/print-strip-template.png` is a 600 x 1776 preview of the template for reference.

## Where the file goes

Save the export as `~/PhotoBooth/print-strip.png`. That is the default path. To use another path, set the `printTemplate` key in `config.json`.

If no file is there, the app prints a plain white strip with the `printCaption` text.

## Tips

- Camera photos are 16:9 and the windows are 3:2, so about 8% is cropped from each side of every photo (centre crop).
- Avoid placing busy design right against the windows if it would clash with the photos.
- The printer is dye-sublimation. Silver and grey print fine, but metallic ink is not possible. Use greys and whites with a gradient to suggest silver.
- Check dark or saturated colours on a test print; dye-sub output usually looks a little different from the screen.
