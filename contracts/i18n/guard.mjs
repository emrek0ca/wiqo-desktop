// Fails when a string that goes over the wire or is matched by code is wrapped in String(localized:), which would translate it.
// A header named "Authorization" became "Autorisierung" in German once; this keeps that from coming back. Run in CI (contracts job).
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const sources = ["RovaIOS", "RovaShared"].flatMap((dir) => readdirSync(join(root, dir)).filter((file) => file.endsWith(".swift")).map((file) => join(dir, file)));
const forbidden = [
  [/forHTTPHeaderField:\s*String\(localized:/, "an HTTP header name is localized"],
  [/setValue\(String\(localized:/, "an HTTP header value is localized"],
  [/String\(localized:\s*"Bearer\b/, "the bearer token is localized"],
  [/String\(localized:\s*"Yerel PC sonuçları hazır/, "the synthetic continuation message the backend matches is localized"],
  [/case\s+\.\w+\s*=\s*String\(localized:/, "an enum raw value is localized"],
  [/phrases:\s*\[String\(localized:/, "an App Shortcut phrase is localized"]
];
let failed = 0;
for (const file of sources) {
  readFileSync(join(root, file), "utf8").split("\n").forEach((line, index) => {
    for (const [pattern, why] of forbidden) {
      if (pattern.test(line)) { console.error(`${file}:${index + 1}: ${why}`); failed++; }
    }
  });
}

// The other direction: a Turkish sentence in the code that is not a catalog key is shown untranslated on every other language.
// `verbatim.json` lists the ones that are meant to stay as written (wire text the backend matches, regexes, comparisons); anything else is a failure.
const keys = JSON.parse(readFileSync(join(root, "contracts", "i18n", "keys.json"), "utf8"));
const fold = (text) => text.replace(/%(?:\d+\$)?(?:lld|lf|@|d|ld|f)/g, "§");
const known = new Set(keys.map(fold));
const verbatim = new Set(JSON.parse(readFileSync(join(root, "contracts", "i18n", "verbatim.json"), "utf8")));
const withoutInterpolation = (text) => {
  let out = "";
  for (let index = 0; index < text.length;) {
    if (text.startsWith("\\(", index)) {
      let depth = 1, end = index + 2;
      while (end < text.length && depth) { depth += (text[end] === "(") - (text[end] === ")"); end++; }
      out += "§"; index = end;
    } else out += text[index++];
  }
  return out;
};
const literal = /"((?:[^"\\]|\\.|\\\((?:[^()]|\([^()]*\))*\))*?[çğıöşüÇĞİÖŞÜ](?:[^"\\]|\\.|\\\((?:[^()]|\([^()]*\))*\))*?)"/g;
for (const file of readdirSync(join(root, "RovaIOS")).filter((name) => name.endsWith(".swift")).map((name) => join("RovaIOS", name))) {
  readFileSync(join(root, file), "utf8").split("\n").forEach((line, index) => {
    if (line.trim().startsWith("//")) return;
    for (const match of line.matchAll(literal)) {
      const raw = match[1];
      if (known.has(withoutInterpolation(raw).replace(/\\n/g, "\n").replace(/\\"/g, '"')) || verbatim.has(raw.slice(0, 80))) continue;
      console.error(`${file}:${index + 1}: Turkish text outside the catalog: "${raw.slice(0, 60)}" (wrap it in String(localized:) or list it in verbatim.json)`);
      failed++;
    }
  });
}
if (failed) process.exit(1);
console.log("no wire identifiers are localized; no Turkish text outside the catalog");
