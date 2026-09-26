// Mac vs Windows operation parity from operations.json (exported from RovaShared). A gap is a
// deliberate "not yet on Windows", visible here - never a silent difference.
import { readFileSync } from "node:fs";

const { operations } = JSON.parse(readFileSync(new URL("./operations.json", import.meta.url), "utf8"));
const windows = operations.filter((item) => item.supportedPlatforms.includes("windows"));
const macOnly = operations.filter((item) => !item.supportedPlatforms.includes("windows"));
const byCapability = new Map();
for (const item of macOnly) byCapability.set(item.capability, [...(byCapability.get(item.capability) ?? []), item.operation]);
console.log(`Parite: Windows ${windows.length}/${operations.length} operasyon · ${new Set(windows.map((item) => item.capability)).size}/${new Set(operations.map((item) => item.capability)).size} yetenek`);
console.log(`Windows'ta olan: ${windows.map((item) => item.operation).join(", ")}`);
console.log("Henüz yalnız Mac'te:");
for (const [capability, list] of [...byCapability].sort()) console.log(`  ${capability}: ${list.join(", ")}`);
