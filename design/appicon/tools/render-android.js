/* render-android.js — 恒牙 App 图标 → Android res 密度渲染器
   用法：node render-android.js <图标交付包路径>
   交付包需含 03-vectors/{source,foreground,background}.svg 与 01-icons/icon-{48,96,192}.png
   （参考交付：hengya-f3-inclined-delivery）

   产物（直接写入 app/android/app/src/main/res/）：
     mipmap-{mdpi..xxxhdpi}/ic_launcher.png                                 48/72/96/144/192
       —— 48/96/192 优先复制交付包官方 PNG（字节不变），72/144 由 source.svg 渲染
     mipmap-{mdpi..xxxhdpi}/ic_launcher_foreground.png                      108/162/216/324/432
     mipmap-{mdpi..xxxhdpi}/ic_launcher_background.png                      同上（自适应图层，66/108 安全区）
     mipmap-anydpi-v26/ic_launcher.xml                                      自适应图标定义
   注意：不会删除或修改 res 下其他文件；重跑幂等（覆盖同名产物）。 */
const fs = require('fs');
const path = require('path');
const { Resvg } = require('@resvg/resvg-js');

const delivery = process.argv[2];
if (!delivery) {
  console.error('用法：node render-android.js <图标交付包路径>');
  process.exit(1);
}
const vecDir = path.join(delivery, '03-vectors');
const iconDir = path.join(delivery, '01-icons');
for (const d of [vecDir, iconDir]) {
  if (!fs.existsSync(d)) {
    console.error(`目录不存在：${d}`);
    process.exit(1);
  }
}

const REPO_ROOT = path.join(__dirname, '..', '..', '..');
const RES = path.join(REPO_ROOT, 'app', 'android', 'app', 'src', 'main', 'res');
if (!fs.existsSync(RES)) {
  console.error(`找不到 Android res 目录：${RES}`);
  process.exit(1);
}

const DENSITIES = ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'];
const LEGACY_SIZES = [48, 72, 96, 144, 192]; // 依次对应五密度
const ADAPTIVE_SIZES = [108, 162, 216, 324, 432]; // 108dp × 各密度倍率
const OFFICIAL_PNG = { 48: 'icon-48.png', 96: 'icon-96.png', 192: 'icon-192.png' };

function renderPng(svgStr, outPath, width) {
  const resvg = new Resvg(svgStr, {
    fitTo: { mode: 'width', value: width },
    background: 'rgba(0,0,0,0)',
  });
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, resvg.render().asPng());
  console.log('  ->', path.relative(REPO_ROOT, outPath));
}

const sourceSvg = fs.readFileSync(path.join(vecDir, 'source.svg'), 'utf8');
const fgSvg = fs.readFileSync(path.join(vecDir, 'foreground.svg'), 'utf8');
const bgSvg = fs.readFileSync(path.join(vecDir, 'background.svg'), 'utf8');

console.log('[legacy ic_launcher]');
DENSITIES.forEach((d, i) => {
  const size = LEGACY_SIZES[i];
  const out = path.join(RES, `mipmap-${d}`, 'ic_launcher.png');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const official = OFFICIAL_PNG[size];
  if (official && fs.existsSync(path.join(iconDir, official))) {
    fs.copyFileSync(path.join(iconDir, official), out); // 官方 PNG 字节不变
    console.log('  ->', path.relative(REPO_ROOT, out), `(官方 ${official})`);
  } else {
    renderPng(sourceSvg, out, size);
  }
});

console.log('[adaptive foreground]');
DENSITIES.forEach((d, i) =>
    renderPng(fgSvg, path.join(RES, `mipmap-${d}`, 'ic_launcher_foreground.png'), ADAPTIVE_SIZES[i]));

console.log('[adaptive background]');
DENSITIES.forEach((d, i) =>
    renderPng(bgSvg, path.join(RES, `mipmap-${d}`, 'ic_launcher_background.png'), ADAPTIVE_SIZES[i]));

console.log('[adaptive icon xml]');
const anydpi = path.join(RES, 'mipmap-anydpi-v26', 'ic_launcher.xml');
fs.mkdirSync(path.dirname(anydpi), { recursive: true });
fs.writeFileSync(
  anydpi,
  `<?xml version="1.0" encoding="utf-8"?>\n` +
  `<!-- 恒牙自适应图标（Android 8+）：F3 随环倾斜版；图层经 66/108 安全区校验 -->\n` +
  `<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n` +
  `    <background android:drawable="@mipmap/ic_launcher_background"/>\n` +
  `    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n` +
  `</adaptive-icon>\n`,
);
console.log('  ->', path.relative(REPO_ROOT, anydpi));
console.log('done');
