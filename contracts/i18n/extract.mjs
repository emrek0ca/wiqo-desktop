// Adds the interface keys of a build to keys.json: node contracts/i18n/extract.mjs <path to RovaIOS.build> (built with SWIFT_EMIT_LOC_STRINGS=YES).
// It only adds; a build that yielded no keys changes nothing (an empty extraction once wiped the catalog).
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2];
if (!root) { console.error("usage: extract.mjs <RovaIOS.build directory>"); process.exit(2); }
const found = new Set();
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else if (name.endsWith(".stringsdata")) for (const item of JSON.parse(readFileSync(path, "utf8")).tables?.Localizable ?? []) if (item.key.trim() !== "") found.add(item.key);
  }
};
walk(root);
if (found.size === 0) { console.error("no keys found: nothing changed"); process.exit(1); }
const file = new URL("./keys.json", import.meta.url);
const keys = JSON.parse(readFileSync(file, "utf8"));
const added = [...found].filter((key) => !keys.includes(key)).sort();
writeFileSync(file, `[\n${[...keys, ...added].map((key) => JSON.stringify(key)).join(",\n")}\n]\n`);
console.log(`${found.size} keys in the build, ${added.length} new`);
for (const key of added) console.log(`+ ${key}`);
