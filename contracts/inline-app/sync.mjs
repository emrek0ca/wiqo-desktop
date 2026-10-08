#!/usr/bin/env node
// Embeds core.js and the libraries into RovaIOS/WiqoInlineAppKit section of WiqoInlineApp.swift (the phone runs them; the project has no resource files to register).
// Usage: node contracts/inline-app/sync.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const target = join(here, "../../RovaIOS/WiqoInlineApp.swift");
const files = { core: "core.js", chart: "chart.js", confetti: "confetti.js", templates: "templates.js" };
const body = Object.entries(files).map(([name, file]) => {
  const source = readFileSync(join(here, file), "utf8").trim();
  if (source.includes('"""#')) throw new Error(`${file} contains the raw-string terminator`);
  return `    static let ${name} = #"""\n${source}\n"""#`;
}).join("\n\n");
const block = `// BEGIN GENERATED inline-app kit (contracts/inline-app/sync.mjs - edit the .js files, not this block)\nenum WiqoInlineKit {\n${body}\n}\n// END GENERATED`;
const swift = readFileSync(target, "utf8");
const pattern = /\/\/ BEGIN GENERATED inline-app kit[\s\S]*?\/\/ END GENERATED/;
writeFileSync(target, pattern.test(swift) ? swift.replace(pattern, () => block) : `${swift.trimEnd()}\n\n${block}\n`);
console.log("WiqoInlineApp.swift güncellendi:", Object.keys(files).join(", "));
