import { test, expect, describe } from "./test-utils.js";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";
import { isProxy } from "node:util/types";

// Type declarations for the Objective-C classes we're testing
interface _NSString extends NobjcObject {
  UTF8String(): string;
  length(): number;
  toString(): string;
}

interface _NSStringConstructor {
  stringWithUTF8String$(str: string): _NSString;
}

describe("JavaScript Code Tests", () => {
  const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  const NSString = Foundation.NSString as unknown as _NSStringConstructor;

  test("should create NSString with stringWithUTF8String$", () => {
    const str = NSString.stringWithUTF8String$("Hello, Objective-C!");
    expect(str).toBeDefined();
  });

  test("should get correct length of NSString", () => {
    const str = NSString.stringWithUTF8String$("Hello, Objective-C!");
    const length = str.length();
    expect(length).toBe(19);
  });

  test("should get UTF8String from NSString", () => {
    const str = NSString.stringWithUTF8String$("Hello, Objective-C!");
    const utf8Str = str.UTF8String();
    expect(utf8Str).toBe("Hello, Objective-C!");
  });

  test("should have toString method", () => {
    const str = NSString.stringWithUTF8String$("Hello, Objective-C!");
    expect(str.toString()).toBeDefined();
  });

  test("should be a proxy object", () => {
    const str = NSString.stringWithUTF8String$("Hello, Objective-C!");
    expect(isProxy(str)).toBe(true);
  });

  test("should have UTF8String method as function", () => {
    const str = NSString.stringWithUTF8String$("Hello, Objective-C!");
    expect(typeof str.UTF8String).toBe("function");
  });
});
