# Capitaine cursors

Copyright (c) 2016 Keefer Rourke and others. Based on KDE Breeze.
Source: https://github.com/keeferrourke/capitaine-cursors
Revision: 06c88433662a4004cf56a6e471b523a0a8880be0
License: LGPL-3.0-or-later; see LICENSE.txt.

Light SVG sources from src/svg/light are included. Near-white (#fefefe) fills
are normalized to white (#ffffff) for exact custom fill colors. PNGs were
rendered at 768 × 768 with @resvg/resvg-js 2.6.2 using
`new Resvg(svg, {fitTo: {mode: 'width', value: 768}}).render().asPng()`.
Hotspots come from src/config/static/*.spec (24-unit source canvas).
Showcase recolors neutral tones at runtime; colored accents retain their hues.
