/**
 * Cross-runtime test shim.
 *
 * Under Bun: re-exports from "bun:test"
 * Under Node (vitest): re-exports from "vitest"
 *
 * Test files import { test, expect, describe } from "./test-utils.js"
 * so they work in both runtimes without modification.
 */

const isBun = typeof globalThis.Bun !== "undefined";

const mod: any = isBun ? await import("bun:test") : await import("vitest");

export const test: typeof import("vitest").test = mod.test;
export const expect: typeof import("vitest").expect = mod.expect;
export const describe: typeof import("vitest").describe = mod.describe;
