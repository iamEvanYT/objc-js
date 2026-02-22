import { test, expect, describe } from "./test-utils.js";
import { NobjcLibrary, NobjcObject, RunLoop } from "../dist/index.js";

// Type declarations for the Objective-C classes we're testing
interface _NSNumber extends NobjcObject {
  integerValue(): number;
  intValue(): number;
}

interface _NSNumberConstructor {
  numberWithInt$(value: number): _NSNumber;
}

interface _NSMutableArray extends NobjcObject {
  count(): number;
  addObject$(obj: NobjcObject): void;
  enumerateObjectsUsingBlock$(block: (obj: NobjcObject, idx: number, stop: any) => void): void;
}

interface _NSMutableArrayConstructor {
  array(): _NSMutableArray;
}

describe("RunLoop Tests", () => {
  describe("RunLoop.pump()", () => {
    test("should return a boolean", () => {
      const result = RunLoop.pump();
      expect(typeof result).toBe("boolean");
    });

    test("should accept a timeout parameter", () => {
      const result = RunLoop.pump(0);
      expect(typeof result).toBe("boolean");
    });

    test("should not throw when no sources are pending", () => {
      const result = RunLoop.pump(0);
      // runMode:beforeDate: may return true or false depending on system state;
      // we only verify it returns a boolean and doesn't crash.
      expect(typeof result).toBe("boolean");
    });

    test("should accept a fractional timeout in seconds", () => {
      // 0.001 seconds = 1ms
      const result = RunLoop.pump(0.001);
      expect(typeof result).toBe("boolean");
    });
  });

  describe("RunLoop.run() and RunLoop.stop()", () => {
    // These tests call run()/stop() synchronously before the interval fires.

    test("run() should return a cleanup function", () => {
      const stop = RunLoop.run();
      expect(typeof stop).toBe("function");
      stop();
    });

    test("run() should accept an interval parameter", () => {
      const stop = RunLoop.run(50);
      expect(typeof stop).toBe("function");
      stop();
    });

    test("cleanup function should stop pumping without error", () => {
      const stop = RunLoop.run();
      expect(() => stop()).not.toThrow();
    });

    test("run() should replace previous timer when called multiple times", () => {
      const stop1 = RunLoop.run(10);
      const stop2 = RunLoop.run(20);
      expect(() => stop1()).not.toThrow();
      expect(() => stop2()).not.toThrow();
    });

    test("stop() should not throw when no timer is running", () => {
      expect(() => RunLoop.stop()).not.toThrow();
    });

    test("stop() should stop a running pump loop", () => {
      RunLoop.run();
      expect(() => RunLoop.stop()).not.toThrow();
    });

    test("stop() should be safe to call multiple times", () => {
      RunLoop.run();
      expect(() => {
        RunLoop.stop();
        RunLoop.stop();
        RunLoop.stop();
      }).not.toThrow();
    });

    test("run-stop-run cycle should work", () => {
      const stop1 = RunLoop.run();
      stop1();

      const stop2 = RunLoop.run();
      stop2();

      const stop3 = RunLoop.run();
      expect(typeof stop3).toBe("function");
      stop3();
    });

    test("stop() after cleanup function should be safe", () => {
      const stop = RunLoop.run();
      stop();
      expect(() => RunLoop.stop()).not.toThrow();
    });
  });

  describe("RunLoop with synchronous blocks", () => {
    test("blocks should work without RunLoop (synchronous enumeration)", () => {
      const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
      const NSNumber = foundation["NSNumber"] as unknown as _NSNumberConstructor;
      const NSMutableArray = foundation["NSMutableArray"] as unknown as _NSMutableArrayConstructor;

      const arr = NSMutableArray.array();
      arr.addObject$(NSNumber.numberWithInt$(1));
      arr.addObject$(NSNumber.numberWithInt$(2));
      arr.addObject$(NSNumber.numberWithInt$(3));

      const values: number[] = [];
      arr.enumerateObjectsUsingBlock$((obj: any, _idx: number, _stop: any) => {
        values.push(obj.intValue());
      });

      expect(values).toEqual([1, 2, 3]);
    });

    test("blocks should work with RunLoop timer set up (synchronous enumeration)", () => {
      const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
      const NSNumber = foundation["NSNumber"] as unknown as _NSNumberConstructor;
      const NSMutableArray = foundation["NSMutableArray"] as unknown as _NSMutableArrayConstructor;

      // Start and immediately stop RunLoop -- verifies no interference
      const stop = RunLoop.run();

      const arr = NSMutableArray.array();
      arr.addObject$(NSNumber.numberWithInt$(10));
      arr.addObject$(NSNumber.numberWithInt$(20));
      arr.addObject$(NSNumber.numberWithInt$(30));

      const values: number[] = [];
      arr.enumerateObjectsUsingBlock$((obj: any, _idx: number, _stop: any) => {
        values.push(obj.intValue());
      });

      expect(values).toEqual([10, 20, 30]);
      stop();
    });
  });

  describe("RunLoop pumping behavior", () => {
    // These tests let the interval fire or call pump() directly,
    // which exercises the NSRunLoop integration.

    test("run() should not block the event loop", async () => {
      const stop = RunLoop.run();

      let eventLoopWorked = false;
      await new Promise<void>((resolve) => {
        setTimeout(() => {
          eventLoopWorked = true;
          resolve();
        }, 50);
      });

      expect(eventLoopWorked).toBe(true);
      stop();
    });

    test("pump() should process a scheduled CFRunLoop timer", async () => {
      const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
      const NSMutableArray = foundation["NSMutableArray"] as unknown as _NSMutableArrayConstructor;
      const NSNumber = foundation["NSNumber"] as unknown as _NSNumberConstructor;
      const arr = NSMutableArray.array();
      const marker = NSNumber.numberWithInt$(42);

      // performSelector:withObject:afterDelay: schedules via CFRunLoopTimer
      (arr as any).performSelector$withObject$afterDelay$("addObject:", marker, 0.0);

      // The item is NOT added synchronously -- it's queued on the run loop
      expect(arr.count()).toBe(0);

      // Give the timer a moment to be ready, then pump
      await new Promise((resolve) => setTimeout(resolve, 50));
      RunLoop.pump(0.05);

      expect(arr.count()).toBe(1);
    });

    test("run() should deliver scheduled CFRunLoop timers automatically", async () => {
      const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
      const NSMutableArray = foundation["NSMutableArray"] as unknown as _NSMutableArrayConstructor;
      const NSNumber = foundation["NSNumber"] as unknown as _NSNumberConstructor;
      const arr = NSMutableArray.array();
      const marker = NSNumber.numberWithInt$(99);

      const stop = RunLoop.run();

      (arr as any).performSelector$withObject$afterDelay$("addObject:", marker, 0.0);

      // Wait for the run loop to pump and deliver the timer
      await new Promise((resolve) => setTimeout(resolve, 100));

      expect(arr.count()).toBe(1);
      stop();
    });
  });
});
