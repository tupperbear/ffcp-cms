# Client report source

`report.html` (+ `hero.jpg` and `logo-mark.svg`, from the site) prints to the PDF in `docs/client/` with headless Chrome (loads Archivo from Google Fonts):

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --no-pdf-header-footer --virtual-time-budget=10000 --print-to-pdf=../FFCP-website-performance-and-media-2026-11.pdf "file://$PWD/report.html"
```

Publish times come from the Netlify deploy list for `ffcp-website` (15 CMS-hook deploys 2–12 Nov 2026, and the first deploy with the build-speed change, 13 Nov).
