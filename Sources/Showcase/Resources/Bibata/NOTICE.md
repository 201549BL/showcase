# Bibata Modern Ice

Artwork by Abdulkaiz Khatri (ful1e5), from https://github.com/ful1e5/Bibata_Cursor
at commit 35ccfe209a808e40d6c2ca60a46cbe4faf68b690.

Licensed under GPL-3.0; see LICENSE.txt. The SVG source is included alongside
all derived PNGs. Changes: replaced green fill with white and blue outline with
black (the upstream Ice palette); rasterized at 768 × 768 using @resvg/resvg-js
2.6.2. Shapes are unchanged. Each PNG corresponds to the SVG of the same name.

To regenerate, install @resvg/resvg-js@2.6.2 in a temporary directory and render
each SVG using `new Resvg(svg, {fitTo: {mode: 'width', value: 768}}).render().asPng()`.

Hotspots come from configs/normal/x.build.toml in the pinned upstream revision.
The renderer maps its 256-unit coordinates onto a 48-point canvas.
