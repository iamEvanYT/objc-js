import { test, expect, describe } from "./test-utils.js";
import { once } from "node:events";
import { Worker } from "node:worker_threads";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";

interface _NSString extends NobjcObject {}
interface _NSStringConstructor {
  stringWithUTF8String$(str: string): _NSString;
}
interface _NSMutableDictionary extends NobjcObject {
  objectForKey$(key: _NSString): any;
  removeObjectForKey$(key: _NSString): void;
}

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"] as unknown as _NSStringConstructor;
const NSThread = foundation["NSThread"] as any;

describe("Env teardown", () => {
  // Node frees an env's thread-safe functions when it is torn down. Objective-C
  // objects created from that env can outlive it and must not call into it.
  test("objects calling back into JS outlive a terminated worker", async () => {
    const prefix = `NobjcEnvTeardown${Date.now()}`;
    const worker = new Worker(new URL("./workers/outlive-env.js", import.meta.url), { workerData: { prefix } });
    worker.on("error", (error) => {
      throw error;
    });
    await once(worker, "message");
    await worker.terminate();

    const dict = NSThread.mainThread().threadDictionary() as _NSMutableDictionary;
    const key = (name: string) => NSString.stringWithUTF8String$(`${prefix}.${name}`);

    // Block: invoking it used to jump into its freed FFI closure (segfault).
    const operation = dict.objectForKey$(key("block"));
    operation.start();
    expect(operation.isFinished()).toBe(true);

    // Protocol delegate: eviction calls cache:willEvictObject: on it.
    const cache = dict.objectForKey$(key("protocol"));
    cache.setObject$forKey$(key("value"), key("key"));
    expect(() => cache.removeAllObjects()).not.toThrow();

    // Subclass: the JS implementation is gone, so the call returns zero.
    expect(dict.objectForKey$(key("subclass")).answer()).toBe(0);

    // Releasing them releases the block and the delegate's callbacks.
    for (const name of ["block", "protocol", "subclass"]) {
      dict.removeObjectForKey$(key(name));
    }
  });
});
