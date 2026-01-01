import { join } from "node:path";
import { execPath } from "node:process";
import { fileURLToPath } from "node:url";

// This is probably over-engineered, but at least it's clear.

const scriptPath = fileURLToPath(import.meta.url);
console.log("Script path:", scriptPath);
const projectRoot = join(scriptPath, "..", "..");
console.log("Project root:", projectRoot);

// Technical note: N-API is now called Node-API.
// See: https://nodejs.medium.com/renaming-n-api-to-node-api-27aa8ca30ed8

const includePaths = [
  // We need the Node.js headers for Node-API.
  join(execPath, "..", "..", "include", "node"),
  // We need the node-addon-api headers for the C++ bindings that wrap Node-API.
  join(projectRoot, "node_modules", "node-addon-api")
];
for (const path of includePaths) {
  console.log("Adding include path:", path);
}

let flags = ["-std=c++20", "-xobjective-c++", ...includePaths.map((path) => `-I${path}`)];

const clangdConfig = `
CompileFlags:
\tCompiler: /usr/bin/clang++
\tAdd:
${flags.map((flag) => `\t\t- ${flag}`).join("\n")}
`
  // We use `\t` above for clarity, but clangd needs spaces.
  .replace(/\t/g, "  ")
  // We remove the leading newline for cleanliness.
  .trimStart();

import { writeFileSync } from "node:fs";
writeFileSync(join(projectRoot, ".clangd"), clangdConfig);
console.log("Wrote .clangd config file.");
