# Keepshake landing page

A static concept site for the planned Keepshake wristband, personal memory layer, and iOS companion. No backend is required.

Live site: <https://keepshake-band.pages.dev/>

```sh
node build-device.mjs
python3 -m http.server 4173 -d .
```

Open <http://localhost:4173>. Hover over either watch illustration to see the conceptual hardware stack; keyboard focus and the buttons provide the same view on touch devices. The iOS preview cycles through Today, Memory, and Ask, and its buttons select a screen.

The generated `assets/keepshake-device.svg` and `assets/keepshake-device-exploded.svg` use the Anatomy isometric SVG kit in `vendor/anatomy/` (MIT license). The reference enclosure is a design direction, not a finalized hardware specification. The app screens and memory example are illustrative, based on sample content in the project.

To package the public files for static hosting, run `node package-site.mjs` from this directory. This creates `dist/` with only the HTML, CSS, JavaScript, and two device SVGs. For a manual Cloudflare Pages update, run `npx wrangler pages deploy dist --project-name keepshake-band --branch main` after signing in with `npx wrangler login`.
