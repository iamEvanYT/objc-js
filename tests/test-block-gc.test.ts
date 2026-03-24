import { test, expect, describe } from "./test-utils.js";
import { NobjcLibrary, NobjcObject, RunLoop } from "../dist/index.js";
import vm from "node:vm";
import v8 from "node:v8";

interface _NSNumber extends NobjcObject {
  intValue(): number;
}

interface _NSNumberConstructor {
  numberWithInt$(value: number): _NSNumber;
}

interface _NSMutableArray extends NobjcObject {
  addObject$(obj: NobjcObject): void;
  enumerateObjectsUsingBlock$(block: (obj: NobjcObject, idx: number, stop: any) => void): void;
}

interface _NSMutableArrayConstructor {
  array(): _NSMutableArray;
}

interface _NSTimer extends NobjcObject {}

interface _NSTimerConstructor {
  scheduledTimerWithTimeInterval$repeats$block$(
    interval: number,
    repeats: boolean,
    block: (timer: _NSTimer) => void
  ): _NSTimer;
}

type AnyBlock = (...args: any[]) => void;

function createForceGC(): () => void {
  if (typeof Bun !== "undefined" && typeof Bun.gc === "function") {
    const bunGC = Bun.gc;
    return () => bunGC(true);
  }
  if (typeof globalThis.gc === "function") {
    const gc = globalThis.gc;
    return () => gc();
  }

  v8.setFlagsFromString("--expose_gc");
  const gc = vm.runInNewContext("gc");
  if (typeof gc === "function") {
    return () => gc();
  }

  throw new Error("Unable to force garbage collection in this runtime");
}

const forceGC = createForceGC();

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitUntil(predicate: () => boolean, timeoutMs: number, step?: () => void): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    step?.();
    if (predicate()) {
      return;
    }
    await sleep(10);
  }
  throw new Error("Timed out waiting for condition");
}

async function expectBlockEventuallyCollected<T extends AnyBlock>(
  createBlock: () => T,
  useBlock: (block: T) => Promise<void> | void
): Promise<void> {
  let finalized = false;
  const registry = new FinalizationRegistry(() => {
    finalized = true;
  });

  let weakRef: WeakRef<T>;
  {
    let block: T | null = createBlock();
    weakRef = new WeakRef(block);
    registry.register(block, "block");
    await useBlock(block);
    block = null;
  }

  await waitUntil(
    () => {
      forceGC();
      return weakRef.deref() === undefined;
    },
    5000,
    () => {
      forceGC();
      // Create some short-lived pressure so the runtime runs finalizers promptly.
      void new ArrayBuffer(1024 * 1024);
    }
  );

  expect(weakRef.deref()).toBeUndefined();
  // FinalizationRegistry callbacks are best-effort and Bun may delay them even
  // after WeakRef has cleared, so reachability is the assertion that matters.
  void finalized;
}

describe("Block Garbage Collection Tests", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  const NSNumber = foundation["NSNumber"] as unknown as _NSNumberConstructor;
  const NSMutableArray = foundation["NSMutableArray"] as unknown as _NSMutableArrayConstructor;
  const NSTimer = foundation["NSTimer"] as unknown as _NSTimerConstructor;

  test("synchronous blocks should be collectible after invocation returns", async () => {
    const arr = NSMutableArray.array();
    arr.addObject$(NSNumber.numberWithInt$(10));
    arr.addObject$(NSNumber.numberWithInt$(20));
    arr.addObject$(NSNumber.numberWithInt$(30));

    const values: number[] = [];

    await expectBlockEventuallyCollected(
      () => (obj: any) => {
        values.push(obj.intValue());
      },
      (block) => {
        arr.enumerateObjectsUsingBlock$(block as (obj: NobjcObject, idx: number, stop: any) => void);
      }
    );

    expect(values).toEqual([10, 20, 30]);
  });

  test("timer blocks should be collectible after the run loop fires them", async () => {
    let fired = false;

    await expectBlockEventuallyCollected(
      () => (_timer: any) => {
        fired = true;
      },
      async (block) => {
        NSTimer.scheduledTimerWithTimeInterval$repeats$block$(0.001, false, block as (timer: _NSTimer) => void);
        await waitUntil(
          () => fired,
          2000,
          () => {
            RunLoop.pump(0.05);
          }
        );
      }
    );

    expect(fired).toBe(true);
  });
});
