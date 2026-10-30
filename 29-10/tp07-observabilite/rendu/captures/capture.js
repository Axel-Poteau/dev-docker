// Capture d écran headless : node capture.js <url> <fichier.png> <largeur> <hauteur> (image ghcr.io/puppeteer/puppeteer)
const puppeteer = require('puppeteer');
(async () => {
  const [url, out, w, h] = process.argv.slice(2);
  const b = await puppeteer.launch({args: ['--no-sandbox']});
  const p = await b.newPage(); await p.setViewport({width: +w, height: +h});
  await p.goto(url, {waitUntil: 'load', timeout: 60000});
  await new Promise(r => setTimeout(r, 15000));
  await p.screenshot({path: out, fullPage: true}); await b.close();
})();
