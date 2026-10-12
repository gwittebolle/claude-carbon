#!/usr/bin/env node
// render-mascot.mjs: draws docs/mascot-stripes.svg, the README banner, from the mod's own
// frames and palette (hooks/mod/lib/mascot.ts): eight molecules from dark blue to dark
// red, each walking at the pace the /carbon-panel pane gives its colour. A CSS animation, no
// script; still under reduced motion.
// Run: node --experimental-strip-types scripts/render-mascot.mjs

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  eyesFor,
  FRAMES,
  OUTLINE,
  PALETTE,
  SPRITE_HEIGHT,
  SPRITE_WIDTH,
  pixels,
  stepMs,
} from "../hooks/mod/lib/mascot.ts";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const PX = 10;
const GAP = 2 * PX;
const W = SPRITE_WIDTH * PX;
const H = SPRITE_HEIGHT * PX;
const TOTAL = PALETTE.length * W + (PALETTE.length - 1) * GAP;
const LABEL =
  "Eight pixel CO2 molecules, the claude-carbon mascot, walking from dark blue to dark red, the redder the faster";

function path(grid, kind, ox) {
  let d = "";
  grid.forEach((row, y) =>
    row.forEach((v, x) => {
      if (v === kind) d += `M${ox + x * PX} ${y * PX}h${PX}v${PX}h-${PX}z`;
    }),
  );
  return d;
}

function frame(f, ox, color, cls) {
  const grid = pixels(f);
  const eyes = eyesFor(color);
  return (
    `<g class="${cls}">` +
    `<path fill="${OUTLINE}" fill-opacity="0.45" d="${path(grid, "outline", ox)}"/>` +
    `<path fill="${color}" d="${path(grid, "body", ox)}"/>` +
    `<path fill="${eyes}" d="${path(grid, "eye", ox)}"/></g>`
  );
}

const css = [
  ".b{opacity:0}",
  "@keyframes fa{0%{opacity:1}50%{opacity:0}100%{opacity:0}}",
  "@keyframes fb{0%{opacity:0}50%{opacity:1}100%{opacity:1}}",
];
const body = [];
PALETTE.forEach((color, i) => {
  // Out of step with each other, so they do not march in time
  const period = 2 * stepMs(i);
  const anim = `${period}ms steps(1,end) infinite -${i * 137}ms`;
  css.push(`.m${i} .a{animation:fa ${anim}}.m${i} .b{animation:fb ${anim}}`);
  const ox = i * (W + GAP);
  body.push(`<g class="m${i}">${frame(FRAMES[0], ox, color, "a")}${frame(FRAMES[1], ox, color, "b")}</g>`);
});
css.push("@media (prefers-reduced-motion: reduce){.a,.b{animation:none}.a{opacity:1}.b{opacity:0}}");

const svg =
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${TOTAL} ${H}" width="${TOTAL / 2}" height="${H / 2}" shape-rendering="crispEdges" role="img" aria-label="${LABEL}">` +
  `<title>${LABEL}</title><style>${css.join("")}</style>${body.join("")}</svg>\n`;

writeFileSync(join(REPO, "docs/mascot-stripes.svg"), svg);
console.log(`docs/mascot-stripes.svg: ${svg.length} bytes`);
