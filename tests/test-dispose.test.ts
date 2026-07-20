import { describe, expect, test } from "./test-utils.js";
import { dispose, NobjcLibrary, NobjcObject } from "../dist/index.js";

interface NSString extends NobjcObject {
  length(): number;
}

interface NSStringConstructor {
  stringWithUTF8String$(value: string): NSString;
}

describe("dispose", () => {
  const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
  const NSString = Foundation.NSString as unknown as NSStringConstructor;

  test("deterministically releases a wrapped Objective-C object", () => {
    const value = NSString.stringWithUTF8String$("hello");

    dispose(value);

    expect(() => value.length()).toThrow("Objective-C object has been disposed");
  });

  test("is idempotent", () => {
    const value = NSString.stringWithUTF8String$("hello");

    dispose(value);

    expect(() => dispose(value)).not.toThrow();
  });
});
