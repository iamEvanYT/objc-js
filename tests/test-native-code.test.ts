import { test, expect, describe } from "./test-utils.js";
import { once } from "node:events";
import { createRequire } from "node:module";
import { Worker } from "node:worker_threads";
const require = createRequire(import.meta.url);
const isBun = typeof globalThis.Bun !== "undefined";
const nodeOnlyTest = isBun ? test.skip : test;

describe("Native Code Tests", () => {
  test("should load Foundation framework", () => {
    const binding = require("../dist/native");
    expect(() => {
      binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    }).not.toThrow();
  });

  test("should get NSString class object", () => {
    const binding = require("../dist/native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    const NSString = binding.GetClassObject("NSString");
    expect(NSString).toBeDefined();
    expect(NSString.toString()).toBeDefined();
  });

  test("should create NSString object with stringWithUTF8String:", () => {
    const binding = require("../dist/native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    const NSString = binding.GetClassObject("NSString");
    const helloStr = NSString.$msgSend("stringWithUTF8String:", "Hello, Objective-C!");
    expect(helloStr).toBeDefined();
    expect(helloStr.toString()).toBeDefined();
  });

  test("should get length of NSString", () => {
    const binding = require("../dist/native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    const NSString = binding.GetClassObject("NSString");
    const helloStr = NSString.$msgSend("stringWithUTF8String:", "Hello, Objective-C!");
    const length = helloStr.$msgSend("length");
    expect(length).toBe(19);
  });

  test("should get UTF8String from NSString", () => {
    const binding = require("../dist/native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    const NSString = binding.GetClassObject("NSString");
    const helloStr = NSString.$msgSend("stringWithUTF8String:", "Hello, Objective-C!");
    const utf8Str = helloStr.$msgSend("UTF8String");
    expect(utf8Str).toBe("Hello, Objective-C!");
  });

  nodeOnlyTest("should keep ObjcObject constructor isolated per worker env", async () => {
    const binding = require("../dist/native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

    const NSStringBefore = binding.GetClassObject("NSString");
    expect(NSStringBefore).toBeDefined();
    expect(binding.GetPointer(NSStringBefore)).toBeDefined();

    await new Promise<void>((resolve, reject) => {
      const worker = new Worker(new URL("./workers/load-native.js", import.meta.url));

      once(worker, "message").then(() => resolve(), reject);
      worker.on("error", reject);
      worker.on("exit", (code) => {
        if (code !== 0) {
          reject(new Error(`Worker exited with code ${code}`));
        }
      });
    });

    const NSStringAfter = binding.GetClassObject("NSString");
    expect(NSStringAfter).toBeDefined();
    expect(binding.GetPointer(NSStringAfter)).toBeDefined();
  });

  nodeOnlyTest("should clean up env data without crashing when workers terminate", async () => {
    const binding = require("../dist/native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

    const runWorker = () =>
      new Promise<void>((resolve, reject) => {
        const worker = new Worker(new URL("./workers/load-native.js", import.meta.url));

        once(worker, "message").then(() => {
          worker.terminate().then(() => resolve(), reject);
        }, reject);
        worker.on("error", reject);
      });

    // Spawn multiple workers sequentially to exercise cleanup multiple times
    for (let i = 0; i < 3; i++) {
      await runWorker();
    }

    // Verify main thread still works after multiple worker cleanups
    const NSString = binding.GetClassObject("NSString");
    const str = NSString.$msgSend("stringWithUTF8String:", "test");
    expect(str.$msgSend("UTF8String")).toBe("test");
  });
});
