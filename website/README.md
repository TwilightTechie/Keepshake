# Keepshake landing page

A static landing page for the V1 Keepshake wearable prototype, current firmware and native iPhone capture path, and the planned personal memory experience. No backend is required to serve the page.

Live site: <https://keepshake-band.pages.dev/>

```sh
node build-device.mjs
python3 -m http.server 4173 -d .
```

Open <http://localhost:4173>. Hover over either watch illustration to see the conceptual hardware stack; keyboard focus and the buttons provide the same view on touch devices. The iOS preview cycles through Today, Memory, and Ask, and its buttons select a screen. That interface is a product vision; the current native app is the raw audio capture and upload gateway described in [`mobile/ios/README.md`](../mobile/ios/README.md).

The generated `assets/keepshake-device.svg` and `assets/keepshake-device-exploded.svg` use the Anatomy isometric SVG kit in `vendor/anatomy/` (MIT license). The illustrated internal arrangement is explanatory, not a CAD rendering or final hardware specification. Three optimized JPEG photos in `assets/prototype/` document the real V1 wearable. Original enclosure CAD exports live in [`hardware/cad/`](../hardware/cad/).

To package the public files for static hosting, run `node package-site.mjs` from this directory. This creates `dist/` with only the HTML, CSS, JavaScript, two device SVGs, and three optimized photos. For a manual Cloudflare Pages update, run `npx wrangler pages deploy dist --project-name keepshake-band --branch main` after signing in with `npx wrangler login`.
