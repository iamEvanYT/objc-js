import { test, expect, describe } from "./test-utils.js";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";
import { isProxy } from "node:util/types";

/**
 * Tests for ObjC object lifecycle (retain/release) correctness.
 *
 * The bug: ObjcObject held unretained references to native ObjC objects.
 * -fobjc-arc was in OTHER_CFLAGS (C/ObjC) instead of OTHER_CPLUSPLUSFLAGS
 * (C++/ObjC++), so ARC was never active for the .mm source files.
 * The __strong id member was inert — no retain on construction, no release
 * on destruction. Objects passed through completion handler block callbacks
 * would be deallocated by ARC/autorelease after the handler returned,
 * leaving ObjcObject holding a dangling pointer → SIGTRAP.
 *
 * The fix: Explicit objc_retain in ObjcObject constructor, objc_release
 * in destructor.
 */

// Type declarations
interface _NSString extends NobjcObject {
  UTF8String(): string;
  length(): number;
  toString(): string;
  uppercaseString(): _NSString;
  substringToIndex$(index: number): _NSString;
}

interface _NSStringConstructor {
  stringWithUTF8String$(str: string): _NSString;
  stringWithFormat$(format: _NSString, ...args: any[]): _NSString;
}

interface _NSNumber extends NobjcObject {
  intValue(): number;
  doubleValue(): number;
  stringValue(): _NSString;
}

interface _NSNumberConstructor {
  numberWithInt$(value: number): _NSNumber;
}

interface _NSArray extends NobjcObject {
  count(): number;
  objectAtIndex$(index: number): NobjcObject;
  firstObject(): NobjcObject;
  lastObject(): NobjcObject;
  enumerateObjectsUsingBlock$(block: (obj: NobjcObject, idx: number, stop: any) => void): void;
}

interface _NSMutableArray extends _NSArray {
  addObject$(obj: NobjcObject): void;
}

interface _NSMutableArrayConstructor {
  array(): _NSMutableArray;
}

interface _NSURL extends NobjcObject {
  absoluteString(): _NSString;
  path(): _NSString;
}

interface _NSURLConstructor {
  URLWithString$(str: _NSString): _NSURL;
  fileURLWithPath$(path: _NSString): _NSURL;
}

interface _NSURLSession extends NobjcObject {
  dataTaskWithURL$completionHandler$(
    url: _NSURL,
    handler: (data: any, response: any, error: any) => void
  ): _NSURLSessionDataTask;
}

interface _NSURLSessionConstructor {
  sharedSession(): _NSURLSession;
}

interface _NSURLSessionDataTask extends NobjcObject {
  resume(): void;
}

describe("Object Lifecycle Tests", () => {
  const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  const NSString = Foundation.NSString as unknown as _NSStringConstructor;
  const NSNumber = Foundation.NSNumber as unknown as _NSNumberConstructor;
  const NSMutableArray = Foundation.NSMutableArray as unknown as _NSMutableArrayConstructor;
  const NSURL = Foundation.NSURL as unknown as _NSURLConstructor;
  const NSURLSession = Foundation.NSURLSession as unknown as _NSURLSessionConstructor;

  // -- Basic retention: method return values --

  test("autoreleased return values should be retained and usable", () => {
    // stringWithUTF8String: returns an autoreleased object.
    // Without retain, it would be freed when the autorelease pool drains.
    const str = NSString.stringWithUTF8String$("retained string");
    expect(str.UTF8String()).toBe("retained string");
    expect(str.length()).toBe(15);
  });

  test("chained method return values should each be retained", () => {
    // Each intermediate result is an autoreleased object.
    const str = NSString.stringWithUTF8String$("hello world");
    const upper = str.uppercaseString();
    const sub = upper.substringToIndex$(5);

    // All three objects must still be alive
    expect(str.UTF8String()).toBe("hello world");
    expect(upper.UTF8String()).toBe("HELLO WORLD");
    expect(sub.UTF8String()).toBe("HELLO");
  });

  test("many autoreleased objects created in a loop should all survive", () => {
    // Stress test: create many autoreleased objects and verify they all
    // survive. Without retain, some would be freed when the autorelease
    // pool drains at the end of a run loop iteration.
    const objects: _NSString[] = [];
    for (let i = 0; i < 100; i++) {
      objects.push(NSString.stringWithUTF8String$(`object-${i}`));
    }

    // Verify all objects are still valid
    for (let i = 0; i < 100; i++) {
      expect(objects[i].UTF8String()).toBe(`object-${i}`);
    }
  });

  // -- Block callback argument retention --

  test("block callback args should be NobjcObject proxies", () => {
    const arr = NSMutableArray.array();
    arr.addObject$(NSString.stringWithUTF8String$("test"));

    let receivedObj: any = null;

    (arr as _NSArray).enumerateObjectsUsingBlock$((obj: any, _idx: number, _stop: any) => {
      receivedObj = obj;
    });

    // The object received in the block should be a Proxy (NobjcObject),
    // not a raw ObjcObject
    expect(receivedObj).not.toBeNull();
    expect(isProxy(receivedObj)).toBe(true);
  });

  test("block callback args should be usable after the block returns", () => {
    const arr = NSMutableArray.array();
    arr.addObject$(NSNumber.numberWithInt$(42));
    arr.addObject$(NSNumber.numberWithInt$(99));
    arr.addObject$(NSString.stringWithUTF8String$("hello"));

    // Store references to objects received in the block callback
    const stored: any[] = [];

    (arr as _NSArray).enumerateObjectsUsingBlock$((obj: any, _idx: number, _stop: any) => {
      stored.push(obj);
    });

    // Use the stored objects AFTER the block has returned.
    // Without retain, these could be freed if the enumeration created
    // autoreleased temporaries.
    expect(stored.length).toBe(3);
    expect(stored[0].intValue()).toBe(42);
    expect(stored[1].intValue()).toBe(99);
    expect(stored[2].UTF8String()).toBe("hello");
  });

  test("block callback args should support chained method calls after block returns", () => {
    const arr = NSMutableArray.array();
    arr.addObject$(NSString.stringWithUTF8String$("chain test"));

    let stored: any = null;

    (arr as _NSArray).enumerateObjectsUsingBlock$((obj: any, _idx: number, _stop: any) => {
      stored = obj;
    });

    // Chain multiple method calls on the stored object
    const upper = stored.uppercaseString();
    const sub = upper.substringToIndex$(5);
    expect(sub.UTF8String()).toBe("CHAIN");
  });

  // -- Async completion handler (TSFN path) --
  // This is the exact pattern that caused the SIGTRAP crashes: objects
  // received from a background-thread completion handler, used after the
  // handler has returned and its autorelease pool has drained.

  test("async completion handler objects survive after callback returns", async () => {
    const session = NSURLSession.sharedSession();
    const url = NSURL.fileURLWithPath$(NSString.stringWithUTF8String$("/etc/hosts") as any);

    const result = await new Promise<{
      data: any;
      response: any;
      error: any;
    }>((resolve) => {
      const task = session.dataTaskWithURL$completionHandler$(url, (data: any, response: any, error: any) => {
        // This callback is invoked from a background thread (NSURLSession's
        // delegate queue) and dispatched to the JS thread via TSFN.
        // The objects (data, response, error) are autoreleased in the
        // background thread's autorelease pool. Without objc_retain in
        // ObjcObject's constructor, they'd be freed when this callback
        // returns and the pool drains.
        resolve({ data, response, error });
      });
      task.resume();
    });

    // We're now on a later event loop tick. The completion handler has
    // returned, the background thread's autorelease pool has drained.
    // These objects should still be alive thanks to objc_retain.

    if (result.error != null && typeof result.error === "object") {
      // Even errors should be valid objects
      expect(isProxy(result.error)).toBe(true);
      expect(typeof result.error.localizedDescription()).toBe("string");
    } else {
      // Verify data is valid and has content
      expect(result.data).not.toBeNull();
      expect(isProxy(result.data)).toBe(true);
      const dataLength = result.data.length();
      expect(dataLength).toBeGreaterThan(0);

      // Verify response is valid and has the correct URL
      expect(result.response).not.toBeNull();
      expect(isProxy(result.response)).toBe(true);

      // Chain through response.URL.path — exercises retention of
      // intermediate autoreleased objects from method calls on
      // an object that itself came from an async callback
      const responseURL = result.response.URL();
      expect(isProxy(responseURL)).toBe(true);
      const urlPath = responseURL.path();
      expect(urlPath.toString()).toBe("/etc/hosts");
    }
  });

  test("multiple async completion handlers should all retain objects", async () => {
    const session = NSURLSession.sharedSession();

    // Fire two async requests concurrently
    const urls = ["/etc/hosts", "/etc/resolv.conf"];
    const promises = urls.map(
      (path) =>
        new Promise<{ data: any; response: any; error: any }>((resolve) => {
          const url = NSURL.fileURLWithPath$(NSString.stringWithUTF8String$(path) as any);
          const task = session.dataTaskWithURL$completionHandler$(url, (data: any, response: any, error: any) => {
            resolve({ data, response, error });
          });
          task.resume();
        })
    );

    const results = await Promise.all(promises);

    // Both results should have valid, retained objects
    for (let i = 0; i < results.length; i++) {
      const { data, response, error } = results[i];

      if (error != null && typeof error === "object") {
        expect(isProxy(error)).toBe(true);
      } else {
        expect(data).not.toBeNull();
        expect(data.length()).toBeGreaterThan(0);
        expect(response).not.toBeNull();
        const path = response.URL().path();
        expect(path.toString()).toBe(urls[i]);
      }
    }
  });
});
