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
if (failed) process.exit(1);
console.log("no wire identifiers are localized");
