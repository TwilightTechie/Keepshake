import { cp, mkdir, rm } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const output = join(root, 'dist');
const files = [
  'index.html',
  'styles.css',
  'script.js',
  'assets/keepshake-device.svg',
  'assets/keepshake-device-exploded.svg',
];

await rm(output, { recursive: true, force: true });
for (const file of files) {
  const destination = join(output, file);
  await mkdir(dirname(destination), { recursive: true });
  await cp(join(root, file), destination);
}
console.log(`Packaged ${files.length} public files in ${output}`);
