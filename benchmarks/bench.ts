/**
 * Performance benchmark suite for nobjc.
 *
 * Measures ops/sec for all critical hot paths:
 *   - $msgSend throughput (simple calls, string returns, multi-arg)
 *   - Method proxy caching (repeated access vs. unique access)
 *   - Property access guard (built-in props, has-check)
 *   - Struct packing / unpacking (CGRect, CGPoint, NSRange)
 *   - Object wrapping / argument unwrapping
 *   - String creation throughput
 *
 * Results are written to benchmarks/RESULTS.md after each run.
 *
 * Usage:
 *   npm run bench
 *   bun run benchmarks/bench.ts
 */

import { writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

interface BenchResult {
  name: string;
  ops: number;
  opsPerSec: number;
  avgNs: number;
  totalMs: number;
  iterations: number;
}

const PAD_NAME = 52;
const WARMUP_MS = 100;
const TARGET_MS = 2000;
const MIN_ITERATIONS = 100;

function bench(name: string, fn: () => void): BenchResult {
  // Warmup
  const warmupEnd = performance.now() + WARMUP_MS;
  while (performance.now() < warmupEnd) fn();

  // Calibration: figure out how many ops fit in ~100ms
  let calibrationOps = 0;
  const calStart = performance.now();
  while (performance.now() - calStart < 100) {
    fn();
    calibrationOps++;
  }
  const calElapsed = performance.now() - calStart;

  // Use calibration to pick a batch size (aim for ~50ms per batch)
  const batchSize = Math.max(MIN_ITERATIONS, Math.round((calibrationOps / calElapsed) * 50));

  // Measured run
  let totalOps = 0;
  const deadline = performance.now() + TARGET_MS;
  const runStart = performance.now();

  while (performance.now() < deadline) {
    for (let i = 0; i < batchSize; i++) fn();
    totalOps += batchSize;
  }

  const totalMs = performance.now() - runStart;
  const opsPerSec = (totalOps / totalMs) * 1000;
  const avgNs = (totalMs / totalOps) * 1e6;

  return { name, ops: totalOps, opsPerSec, avgNs, totalMs, iterations: totalOps };
}

function formatNumber(n: number): string {
  if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(2) + "K";
  return n.toFixed(2);
}

function printResult(r: BenchResult) {
  const name = r.name.padEnd(PAD_NAME);
  const ops = (formatNumber(r.opsPerSec) + " ops/sec").padStart(18);
  const ns = (r.avgNs.toFixed(0) + " ns/op").padStart(12);
  console.log(`  ${name} ${ops} ${ns}`);
}

function printHeader(title: string) {
  console.log();
  console.log(`${"─".repeat(PAD_NAME + 34)}`);
  console.log(`  ${title}`);
  console.log(`${"─".repeat(PAD_NAME + 34)}`);
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const AppKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");

const NSString = Foundation.NSString as any;
const NSNumber = Foundation.NSNumber as any;
const NSValue = Foundation.NSValue as any;
const NSArray = Foundation.NSArray as any;
const NSMutableArray = Foundation.NSMutableArray as any;
const NSMutableDictionary = Foundation.NSMutableDictionary as any;

// Pre-create objects used across benchmarks
const helloStr = NSString.stringWithUTF8String$("Hello, Objective-C!");
const num42 = NSNumber.numberWithInt$(42);

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

const allResults: BenchResult[] = [];

function run(name: string, fn: () => void) {
  const r = bench(name, fn);
  allResults.push(r);
  printResult(r);
}

// -- $msgSend throughput ----------------------------------------------------

printHeader("$msgSend Throughput");

run("$msgSend: length (no args, int return)", () => {
  helloStr.length();
});

run("$msgSend: UTF8String (no args, string return)", () => {
  helloStr.UTF8String();
});

run("$msgSend: isEqualToString: (1 obj arg, bool return)", () => {
  helloStr.isEqualToString$(helloStr);
});

run("$msgSend: stringWithUTF8String: (1 string arg)", () => {
  NSString.stringWithUTF8String$("bench");
});

run("$msgSend: numberWithInt: (1 int arg)", () => {
  NSNumber.numberWithInt$(7);
});

run("$msgSend: intValue (no args, int return)", () => {
  num42.intValue();
});

run("$msgSend: substringWithRange: (struct arg)", () => {
  helloStr.substringWithRange$({ location: 0, length: 5 });
});

run("$msgSend: rangeOfString: (obj arg, struct return)", () => {
  const search = NSString.stringWithUTF8String$("Obj");
  helloStr.rangeOfString$(search);
});

run("$msgSend: stringByAppendingString: (obj arg, obj return)", () => {
  const suffix = NSString.stringWithUTF8String$(" World");
  helloStr.stringByAppendingString$(suffix);
});

run("$msgSend: respondsToSelector: via 'in' operator", () => {
  "length" in helloStr;
});

// -- Method proxy caching ---------------------------------------------------

printHeader("Method Proxy Access");

run("method access: same method repeated (cached)", () => {
  // Accessing the same method name should hit the WeakMap cache
  const _ = helloStr.length;
});

run("method access + call: length() repeated", () => {
  helloStr.length();
});

run("method access: toString()", () => {
  helloStr.toString();
});

// -- Property access guard --------------------------------------------------

printHeader("Property Access Guard (built-in props)");

run("built-in prop: constructor", () => {
  (helloStr as any).constructor;
});

run("built-in prop: valueOf", () => {
  (helloStr as any).valueOf;
});

run("built-in prop: hasOwnProperty", () => {
  (helloStr as any).hasOwnProperty;
});

// -- Struct operations ------------------------------------------------------

printHeader("Struct Operations");

run("struct arg: NSRange (2 fields)", () => {
  helloStr.substringWithRange$({ location: 0, length: 5 });
});

run("struct arg: CGPoint via NSValue", () => {
  NSValue.valueWithPoint$({ x: 42.5, y: 99.0 });
});

run("struct arg: CGSize via NSValue", () => {
  NSValue.valueWithSize$({ width: 640.0, height: 480.0 });
});

run("struct arg: CGRect via NSValue (nested)", () => {
  NSValue.valueWithRect$({
    origin: { x: 10.0, y: 20.0 },
    size: { width: 300.0, height: 200.0 }
  });
});

const nsRangeValue = NSValue.valueWithRange$({ location: 42, length: 100 });
run("struct return: NSRange via rangeValue", () => {
  nsRangeValue.rangeValue();
});

const cgPointValue = NSValue.valueWithPoint$({ x: 1.0, y: 2.0 });
run("struct return: CGPoint via pointValue", () => {
  cgPointValue.pointValue();
});

const cgRectValue = NSValue.valueWithRect$({
  origin: { x: 0, y: 0 },
  size: { width: 100, height: 100 }
});
run("struct return: CGRect via rectValue (nested)", () => {
  cgRectValue.rectValue();
});

run("struct roundtrip: CGRect pack + unpack", () => {
  const v = NSValue.valueWithRect$({
    origin: { x: 1.5, y: 2.5 },
    size: { width: 100.25, height: 200.75 }
  });
  v.rectValue();
});

// -- Object wrapping / unwrapping -------------------------------------------

printHeader("Object Wrapping & Arguments");

run("pass NobjcObject as argument", () => {
  helloStr.isEqualToString$(helloStr);
});

run("create + wrap NSString", () => {
  NSString.stringWithUTF8String$("test");
});

run("create + wrap NSNumber", () => {
  NSNumber.numberWithDouble$(3.14);
});

run("NSMutableArray: addObject + removeLastObject", () => {
  const arr = NSMutableArray.array();
  arr.addObject$(num42);
  arr.removeLastObject();
});

// -- String operations ------------------------------------------------------

printHeader("String Operations");

run("NSString creation: short (5 chars)", () => {
  NSString.stringWithUTF8String$("Hello");
});

run("NSString creation: medium (50 chars)", () => {
  NSString.stringWithUTF8String$("The quick brown fox jumps over the lazy dog, again!");
});

run("NSString creation: long (500 chars)", () => {
  NSString.stringWithUTF8String$("A".repeat(500));
});

run("NSString UTF8String extraction", () => {
  helloStr.UTF8String();
});

run("NSString toString (description)", () => {
  helloStr.toString();
});

run("NSString length", () => {
  helloStr.length();
});

// -- Multi-argument calls ---------------------------------------------------

printHeader("Multi-Argument Calls");

run("2 args: NSString compare:options:", () => {
  const other = NSString.stringWithUTF8String$("Hello, Objective-C!");
  // NSCaseInsensitiveSearch = 1
  helloStr.compare$options$(other, 1);
});

run("4 args: NSWindow initWithContentRect:...", () => {
  const NSWindow = AppKit.NSWindow as any;
  NSWindow.alloc().initWithContentRect$styleMask$backing$defer$(
    { origin: { x: 0, y: 0 }, size: { width: 200, height: 200 } },
    1 | 2,
    2,
    true
  );
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

console.log();
console.log("═".repeat(PAD_NAME + 34));
console.log("  SUMMARY");
console.log("═".repeat(PAD_NAME + 34));

// Sort by ops/sec descending
const sorted = [...allResults].sort((a, b) => b.opsPerSec - a.opsPerSec);
const fastest = sorted[0];
const slowest = sorted[sorted.length - 1];

console.log(`  Total benchmarks:  ${allResults.length}`);
console.log(`  Fastest:           ${fastest.name} (${formatNumber(fastest.opsPerSec)} ops/sec)`);
console.log(`  Slowest:           ${slowest.name} (${formatNumber(slowest.opsPerSec)} ops/sec)`);
console.log();

// ---------------------------------------------------------------------------
// Write results to markdown
// ---------------------------------------------------------------------------

function getGitHash(): string {
  try {
    return execSync("git rev-parse --short HEAD", { encoding: "utf-8" }).trim();
  } catch {
    return "unknown";
  }
}

function generateMarkdown(): string {
  const now = new Date();
  const timestamp = now
    .toISOString()
    .replace("T", " ")
    .replace(/\.\d+Z$/, " UTC");
  const gitHash = getGitHash();
  const arch = process.arch;
  const platform = process.platform;
  const runtime = typeof Bun !== "undefined" ? `Bun ${Bun.version}` : `Node ${process.version}`;

  const lines: string[] = [];
  lines.push("# Benchmark Results");
  lines.push("");
  lines.push(`> Generated: ${timestamp}  `);
  lines.push(`> Git: \`${gitHash}\`  `);
  lines.push(`> Runtime: ${runtime}  `);
  lines.push(`> Platform: ${platform} ${arch}`);
  lines.push("");

  // Group results by category (reconstructed from section headers)
  const categories: { title: string; results: BenchResult[] }[] = [];
  let currentCategory: { title: string; results: BenchResult[] } | null = null;

  for (const r of allResults) {
    const cat = getCategoryForBench(r.name);
    if (!currentCategory || currentCategory.title !== cat) {
      currentCategory = { title: cat, results: [] };
      categories.push(currentCategory);
    }
    currentCategory.results.push(r);
  }

  for (const cat of categories) {
    lines.push(`## ${cat.title}`);
    lines.push("");
    lines.push("| Benchmark | ops/sec | ns/op |");
    lines.push("| :--- | ---: | ---: |");
    for (const r of cat.results) {
      lines.push(`| ${r.name} | ${formatNumber(r.opsPerSec)} | ${r.avgNs.toFixed(0)} |`);
    }
    lines.push("");
  }

  lines.push("## Summary");
  lines.push("");
  lines.push(`- **Total benchmarks:** ${allResults.length}`);
  lines.push(`- **Fastest:** ${fastest.name} (${formatNumber(fastest.opsPerSec)} ops/sec)`);
  lines.push(`- **Slowest:** ${slowest.name} (${formatNumber(slowest.opsPerSec)} ops/sec)`);
  lines.push("");

  return lines.join("\n");
}

function getCategoryForBench(name: string): string {
  if (name.startsWith("$msgSend")) return "$msgSend Throughput";
  if (name.startsWith("method access")) return "Method Proxy Access";
  if (name.startsWith("built-in prop")) return "Property Access Guard";
  if (name.startsWith("struct")) return "Struct Operations";
  if (name.startsWith("pass Nobjc") || name.startsWith("create + wrap") || name.startsWith("NSMutable"))
    return "Object Wrapping & Arguments";
  if (name.startsWith("NSString")) return "String Operations";
  if (name.match(/^\d+ args/)) return "Multi-Argument Calls";
  return "Other";
}

const benchDir = dirname(fileURLToPath(import.meta.url));
const resultsPath = join(benchDir, "RESULTS.md");
const md = generateMarkdown();
writeFileSync(resultsPath, md);
console.log(`Results written to benchmarks/RESULTS.md`);
