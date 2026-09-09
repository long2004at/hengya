/* render.js — 恒牙 App 图标概念稿渲染器（SVG -> PNG）
   用法：node render.js
   输出：
     ../png/full/<base>_{1024,512,192,96,48}.png  完整图标（真实光栅，48px 为诚实辨识度测试）
     ../png/fg/<base>_fg_1024.png                  前景层（透明底，仅主图形）
     ../png/bg/<base>_bg_1024.png                 背景层（满幅底色） */
const fs = require('fs');
const path = require('path');
const { Resvg } = require('@resvg/resvg-js');

const ROOT = path.join(__dirname, '..');
const SVG_DIR = path.join(ROOT, 'svg');
const DIRS = {
  full: path.join(ROOT, 'png', 'full'),
  fg: path.join(ROOT, 'png', 'fg'),
  bg: path.join(ROOT, 'png', 'bg'),
};
const SIZES = [1024, 512, 192, 96, 48];

/* 深度优先移除一个指定 id 的组（支持组内嵌套） */
function removeGroup(svg, id) {
  const open = svg.indexOf(`<g id="${id}"`);
  if (open < 0) return svg;
  const tagRe = /<\/?g[\s>]/g;
  tagRe.lastIndex = open;
  let depth = 0, end = svg.length, t;
  while ((t = tagRe.exec(svg))) {
    depth += svg[t.index + 1] === '/' ? -1 : 1;
    if (depth === 0) { end = t.index + t[0].length; break; }
  }
  return svg.slice(0, open) + svg.slice(end);
}

function renderPng(svgStr, outPath, width) {
  const resvg = new Resvg(svgStr, {
    fitTo: { mode: 'width', value: width },
    background: 'rgba(0,0,0,0)',
  });
  fs.writeFileSync(outPath, resvg.render().asPng());
  console.log('  ->', path.relative(process.cwd(), outPath));
}

const files = fs.readdirSync(SVG_DIR).filter(f => f.endsWith('.svg')).sort();
if (files.length === 0) {
  console.error('svg/ 目录下没有找到 .svg 文件');
  process.exit(1);
}
for (const f of files) {
  const svg = fs.readFileSync(path.join(SVG_DIR, f), 'utf8');
  const base = f.replace(/\.svg$/, '');
  console.log(`[${base}]`);
  for (const s of SIZES) {
    renderPng(svg, path.join(DIRS.full, `${base}_${s}.png`), s);
  }
  renderPng(removeGroup(svg, 'background'), path.join(DIRS.fg, `${base}_fg_1024.png`), 1024);
  renderPng(removeGroup(svg, 'foreground'), path.join(DIRS.bg, `${base}_bg_1024.png`), 1024);
}
console.log(`done: ${files.length} concepts x ${SIZES.length + 2} renders`);
