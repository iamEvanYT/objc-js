import { test, expect, describe } from "bun:test";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);

describe("Native Code Tests", () => {
  test("should load Foundation framework", () => {
    const binding = require("#nobjc_native");
    expect(() => {
      binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    }).not.toThrow();
  });

  test("should get NSString class object", () => {
    const binding = require("#nobjc_native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    const NSString = binding.GetClassObject("NSString");
    expect(NSString).toBeDefined();
    expect(NSString.toString()).toBeDefined();
  });

  test("should create NSString object with stringWithUTF8String:", () => {
    const binding = require("#nobjc_native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    const NSString = binding.GetClassObject("NSString");
    const helloStr = NSString.$msgSend("stringWithUTF8String:", "Hello, Objective-C!");
    expect(helloStr).toBeDefined();
    expect(helloStr.toString()).toBeDefined();
  });

  test("should get length of NSString", () => {
    const binding = require("#nobjc_native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    const NSString = binding.GetClassObject("NSString");
    const helloStr = NSString.$msgSend("stringWithUTF8String:", "Hello, Objective-C!");
    const length = helloStr.$msgSend("length");
    expect(length).toBe(19);
  });

  test("should get UTF8String from NSString", () => {
    const binding = require("#nobjc_native");
    binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
    const NSString = binding.GetClassObject("NSString");
    const helloStr = NSString.$msgSend("stringWithUTF8String:", "Hello, Objective-C!");
    const utf8Str = helloStr.$msgSend("UTF8String");
    expect(utf8Str).toBe("Hello, Objective-C!");
  });
});
