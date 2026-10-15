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
  let current;
  try { current = JSON.parse(readFileSync(output, "utf8")); } catch { /* reported below */ }
  const expected = JSON.parse(rendered);
  const canonical = (value) => Array.isArray(value)
    ? `[${value.map(canonical).join(",")}]`
    : value && typeof value === "object"
      ? `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`
      : JSON.stringify(value);
  // Xcode may add extracted keys and update the catalog schema version. Verify every key
  // generated from translations.json, while preserving those additional catalog entries.
  const stale = !current
    || current.sourceLanguage !== expected.sourceLanguage
    || Object.entries(expected.strings).some(([key, value]) => canonical(current.strings?.[key]) !== canonical(value));
  if (stale) { console.error("RovaIOS/Localizable.xcstrings is stale: run node contracts/i18n/build.mjs and commit it."); exit(1); }
  if (missing.length > 0) { console.error(`${missing.length} keys lack a translation, e.g. ${JSON.stringify(missing[0])}`); exit(1); }
  console.log(`catalog current: ${keys.length} strings, ${languages.length} languages`);
  exit(0);
}

writeFileSync(output, rendered);
console.log(`${Object.keys(strings).length} strings, ${Object.keys(translations).length} languages`);
