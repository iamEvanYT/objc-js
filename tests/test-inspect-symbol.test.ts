import { test, expect, describe } from "./test-utils.js";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";
import { inspect } from "node:util";

/**
 * Test for the console.log / inspect symbol regression.
 *
 * The bug: Commit 25c7555 (tier 1 perf improvements) moved the
 * customInspectSymbol from a direct property on the native ObjcObject
 * to the Proxy's `get` trap to avoid V8 hidden class transitions. But
 * Node and Bun bypass Proxy traps during console.log/util.inspect and
 * read the target object directly. Since the symbol was no longer on the
 * target, console.log fell back to showing raw `ObjcObject { $msgSend: ... }`
 * internals instead of the ObjC description.
 *
 * The fix: Restore the property mutation on the native object AND keep
 * it in the get trap as belt-and-suspenders.
 */

describe("Inspect Symbol Tests", () => {
  const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  interface _NSString extends NobjcObject {
    stringWithUTF8String$(str: string): _NSString;
    UTF8String(): string;
  }

  interface _NSNumber extends NobjcObject {
    numberWithInt$(value: number): _NSNumber;
    intValue(): number;
  }

  const NSString = Foundation.NSString as unknown as _NSString;
  const NSNumber = Foundation.NSNumber as unknown as _NSNumber;

  test("util.inspect should show ObjC description, not raw internals", () => {
    const str = NSString.stringWithUTF8String$("Hello, World!");
    const inspected = inspect(str);

    // Should contain the actual string content (ObjC description)
    expect(inspected).toContain("Hello, World!");

    // Should NOT show raw ObjcObject internals
    expect(inspected).not.toContain("$msgSend");
    expect(inspected).not.toContain("$respondsToSelector");
    expect(inspected).not.toContain("$prepareSend");
  });

  test("util.inspect should work for NSNumber objects", () => {
    const num = NSNumber.numberWithInt$(42);
    const inspected = inspect(num);

    // Should show the number description, not raw internals
    expect(inspected).toContain("42");
    expect(inspected).not.toContain("$msgSend");
  });

  test("toString should return ObjC description string", () => {
    const str = NSString.stringWithUTF8String$("test string");
    const result = str.toString();

    expect(result).toBe("test string");
  });

  test("inspect symbol should be accessible on the proxy", () => {
    const str = NSString.stringWithUTF8String$("inspect test");
    const inspectSymbol = Symbol.for("nodejs.util.inspect.custom");

    // The proxy's `has` trap should report true for the inspect symbol
    expect(inspectSymbol in (str as any)).toBe(true);

    // The proxy's `get` trap should return a function for the inspect symbol
    const inspectFn = (str as any)[inspectSymbol];
    expect(typeof inspectFn).toBe("function");

    // Calling it should return the ObjC description
    const result = inspectFn();
    expect(result).toContain("inspect test");
  });

  test("inspect should work on class objects", () => {
    const inspected = inspect(Foundation.NSString);

    // Class objects should show their class name, not raw internals
    expect(inspected).toContain("NSString");
    expect(inspected).not.toContain("$msgSend");
  });

  test("inspect should work on objects accessed via proxy chain", () => {
    // Create an object through a multi-step ObjC call chain
    const str = NSString.stringWithUTF8String$("chained");
    const upper = (str as any).uppercaseString();
    const inspected = inspect(upper);

    expect(inspected).toContain("CHAINED");
    expect(inspected).not.toContain("$msgSend");
  });
});
