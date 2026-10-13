import { test, expect, describe } from "./test-utils.js";
import { NobjcLibrary, NobjcObject, typedBlock } from "../dist/index.js";

// On x86_64 the ObjC runtime encodes BOOL as 'c' (signed char) instead of 'B'.
// These tests check that BOOL behaves the same on both architectures and that
// char values still round-trip.

interface _NSNumber extends NobjcObject {
  boolValue(): boolean;
  intValue(): number;
  charValue(): number | boolean;
}
interface _NSNumberConstructor {
  numberWithBool$(value: boolean): _NSNumber;
  numberWithChar$(value: number | boolean): _NSNumber;
}
interface _NSString extends NobjcObject {
  isEqualToString$(other: _NSString | null): boolean;
}
interface _NSStringConstructor {
  stringWithUTF8String$(str: string): _NSString;
}
interface _NSIndexSet extends NobjcObject {
  count(): number;
}
interface _NSArray extends NobjcObject {
  indexesOfObjectsPassingTest$(predicate: (obj: NobjcObject, idx: number, stop: any) => boolean): _NSIndexSet;
}

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSNumber = foundation["NSNumber"] as unknown as _NSNumberConstructor;
const NSString = foundation["NSString"] as unknown as _NSStringConstructor;
const NSMutableArray = foundation["NSMutableArray"] as any;

describe("BOOL / char encoding", () => {
  test("BOOL return values are booleans", () => {
    const a = NSString.stringWithUTF8String$("hello");
    const b = NSString.stringWithUTF8String$("hello");
    const c = NSString.stringWithUTF8String$("world");
    expect(a.isEqualToString$(b)).toBe(true);
    expect(a.isEqualToString$(c)).toBe(false);
  });

  test("BOOL arguments accept booleans", () => {
    expect(NSNumber.numberWithBool$(true).boolValue()).toBe(true);
    expect(NSNumber.numberWithBool$(false).boolValue()).toBe(false);
  });

  test("char arguments accept numbers", () => {
    expect(NSNumber.numberWithChar$(65).intValue()).toBe(65);
    expect(NSNumber.numberWithChar$(-5).intValue()).toBe(-5);
  });

  test("char arguments accept booleans", () => {
    expect(NSNumber.numberWithChar$(true).intValue()).toBe(1);
    expect(NSNumber.numberWithChar$(false).intValue()).toBe(0);
  });

  test("char return values are booleans only where char encodes BOOL (x86_64)", () => {
    const n = NSNumber.numberWithChar$(65);
    expect(n.charValue()).toBe(process.arch === "x64" ? true : 65);
  });

  test("blocks returning 'c' (x86_64 BOOL) accept booleans from JS", () => {
    const arr = NSMutableArray.array();
    for (let i = 0; i < 5; i++) {
      arr.addObject$(NSNumber.numberWithChar$(i));
    }
    // The runtime only exposes "@?" here, so spell out the x86_64 BOOL encoding
    const predicate = typedBlock({ returns: "c", args: ["@", "Q", "^c"] }, (_obj: NobjcObject, idx: number) => {
      return idx % 2 === 0;
    });
    const evens = (arr as _NSArray).indexesOfObjectsPassingTest$(predicate as any);
    expect(evens.count()).toBe(3);
  });
});
