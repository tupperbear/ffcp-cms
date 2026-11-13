#!/usr/bin/env node
// Prepare a CMS original for re-upload at the media baseline (longest side 2000 px).
// Usage: node scripts/prepare-image.mjs <mode> <in> <out>
//   mode "resizer": for the CMS upload resizer to finish (it makes WebP q80). Images
//          over 2000 px are shrunk to 2000 px as a near-lossless JPEG (PNG if the
//          image has transparency), so the upload is small; smaller ones are copied.
//   mode "webp85": shrunk to 2000 px as WebP quality 85 (for PNGs; uploaded marked
//          "optimized", so the resizer leaves it).
//   mode "estimate": nothing written; prints the size the resizer's WebP q80 would be.
// Orientation from EXIF is applied (the resizer's output has no EXIF either).
// Prints JSON: { out, type, width, height, bytes } (estimate: { bytes, width, height }).
// sharp comes from the site's node_modules (set SHARP_FROM to another package dir).
import { createRequire } from 'node:module';
import { copyFile, stat } from 'node:fs/promises';

const from = process.env.SHARP_FROM || new URL('../../site/package.json', import.meta.url).pathname;
const sharp = createRequire(from)('sharp');
const MAX = 2000;
const [mode, input, output] = process.argv.slice(2);
if (!['resizer', 'webp85', 'estimate'].includes(mode) || !input || (!output && mode !== 'estimate')) {
    console.error('usage: prepare-image.mjs resizer|webp85|estimate <in> [<out>]'); process.exit(2);
}

const meta = await sharp(input, { failOn: 'none' }).metadata();
// Width/height as displayed (EXIF orientations 5-8 swap them)
const [w, h] = (meta.orientation ?? 1) >= 5 ? [meta.height, meta.width] : [meta.width, meta.height];
const resized = () => sharp(input, { failOn: 'none', limitInputPixels: false }).rotate()
    .resize({ width: MAX, height: MAX, fit: 'inside', withoutEnlargement: true });
if (mode === 'estimate') {
    const { data, info } = await resized().webp({ quality: 80 }).toBuffer({ resolveWithObject: true });
    console.log(JSON.stringify({ bytes: data.length, width: info.width, height: info.height }));
    process.exit(0);
}
let type;
if (mode === 'resizer' && Math.max(w, h) <= MAX) {
    await copyFile(input, output);
    type = `image/${meta.format === 'jpg' ? 'jpeg' : meta.format}`;
} else {
    let img = resized();
    if (mode === 'webp85') {
        img = img.webp({ quality: 85 }); type = 'image/webp';
    } else if (meta.hasAlpha) {
        img = img.png({ compressionLevel: 9, adaptiveFiltering: true }); type = 'image/png';
    } else {
        img = img.jpeg({ quality: 95, chromaSubsampling: '4:4:4' }); type = 'image/jpeg';
    }
    await img.toFile(output);
}
const outMeta = await sharp(output).metadata();
console.log(JSON.stringify({ out: output, type, width: outMeta.width, height: outMeta.height, bytes: (await stat(output)).size }));
