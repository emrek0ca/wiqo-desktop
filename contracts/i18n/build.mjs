// Builds RovaIOS/Localizable.xcstrings (source language: Turkish) from translations.json.
//   node contracts/i18n/build.mjs
// translations.json is { "<language>": { "<Turkish key as Swift extracts it>": "<translation>" } }; it is produced by the backend's
// `npm run i18n:catalog` from the keys Xcode extracts (see README.md in this folder). Edit a translation there, run this, commit both.
import { readFileSync, writeFileSync } from "node:fs";
import { argv, exit } from "node:process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const translations = JSON.parse(readFileSync(join(here, "translations.json"), "utf8"));
const keys = JSON.parse(readFileSync(join(here, "keys.json"), "utf8"));

// Leading and trailing spaces and line breaks are part of the key ("\n\nText"): a translation keeps them.
function keepEdges(key, value) {
  const lead = key.match(/^\s*/)[0];
  const trail = key.match(/\s*$/)[0];
  return `${lead}${value.trim()}${trail}`;
}

const strings = {};
for (const key of [...keys].sort()) {
  const localizations = {};
  for (const [language, table] of Object.entries(translations)) {
    if (table[key]) localizations[language] = { stringUnit: { state: "translated", value: keepEdges(key, table[key]) } };
  }
  strings[key] = { extractionState: "manual", localizations };
}
const output = join(here, "..", "..", "RovaIOS", "Localizable.xcstrings");
const rendered = `${JSON.stringify({ sourceLanguage: "tr", strings, version: "1.0" }, null, 2)}\n`;

// --check (CI): the catalog in the repo is exactly what translations.json builds, and no key lacks a language.
if (argv.includes("--check")) {
  const languages = Object.keys(translations);
  const missing = keys.filter((key) => languages.some((language) => !translations[language][key]));
  let current = "";
  try { current = readFileSync(output, "utf8"); } catch { /* reported below */ }
  if (current !== rendered) { console.error("RovaIOS/Localizable.xcstrings is stale: run node contracts/i18n/build.mjs and commit it."); exit(1); }
  if (missing.length > 0) { console.error(`${missing.length} keys lack a translation, e.g. ${JSON.stringify(missing[0])}`); exit(1); }
  console.log(`catalog current: ${keys.length} strings, ${languages.length} languages`);
  exit(0);
}

writeFileSync(output, rendered);
console.log(`${Object.keys(strings).length} strings, ${Object.keys(translations).length} languages`);
