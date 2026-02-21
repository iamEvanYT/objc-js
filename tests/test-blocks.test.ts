import { test, expect, describe } from "bun:test";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";

// Type declarations for the Objective-C classes we're testing
interface _NSString extends NobjcObject {
  UTF8String(): string;
  toString(): string;
  length(): number;
}

interface _NSStringConstructor {
  stringWithUTF8String$(str: string): _NSString;
}

interface _NSNumber extends NobjcObject {
  integerValue(): number;
  intValue(): number;
  doubleValue(): number;
  toString(): string;
}

interface _NSNumberConstructor {
  numberWithInteger$(value: number): _NSNumber;
  numberWithInt$(value: number): _NSNumber;
}

interface _NSArray extends NobjcObject {
  count(): number;
  objectAtIndex$(index: number): NobjcObject;
  enumerateObjectsUsingBlock$(block: (obj: NobjcObject, idx: number, stop: any) => void): void;
}

interface _NSArrayConstructor {
  arrayWithObjects$count$(objects: any, count: number): _NSArray;
  arrayWithObject$(obj: NobjcObject): _NSArray;
}

interface _NSMutableArray extends _NSArray {
  addObject$(obj: NobjcObject): void;
  array(): _NSMutableArray;
}

interface _NSMutableArrayConstructor {
  array(): _NSMutableArray;
}

interface _NSDictionary extends NobjcObject {
  count(): number;
  objectForKey$(key: NobjcObject): NobjcObject;
  enumerateKeysAndObjectsUsingBlock$(block: (key: NobjcObject, obj: NobjcObject, stop: any) => void): void;
}

interface _NSDictionaryConstructor {
  dictionaryWithObject$forKey$(obj: NobjcObject, key: NobjcObject): _NSDictionary;
}

interface _NSMutableDictionary extends _NSDictionary {
  setObject$forKey$(obj: NobjcObject, key: NobjcObject): void;
}

interface _NSMutableDictionaryConstructor {
  dictionary(): _NSMutableDictionary;
}

describe("Block Support Tests", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  const NSString = foundation["NSString"] as unknown as _NSStringConstructor;
  const NSNumber = foundation["NSNumber"] as unknown as _NSNumberConstructor;
  const NSMutableArray = foundation["NSMutableArray"] as unknown as _NSMutableArrayConstructor;
  const NSMutableDictionary = foundation["NSMutableDictionary"] as unknown as _NSMutableDictionaryConstructor;

  test("should enumerate NSArray with enumerateObjectsUsingBlock:", () => {
    // Create a mutable array with some elements
    const arr = NSMutableArray.array();
    arr.addObject$(NSNumber.numberWithInt$(10));
    arr.addObject$(NSNumber.numberWithInt$(20));
    arr.addObject$(NSNumber.numberWithInt$(30));

    // Enumerate using a block
    const collectedValues: number[] = [];
    const collectedIndices: number[] = [];

    (arr as _NSArray).enumerateObjectsUsingBlock$((obj: any, idx: number, _stop: any) => {
      collectedValues.push(obj.intValue());
      collectedIndices.push(idx);
    });

    expect(collectedValues).toEqual([10, 20, 30]);
    expect(collectedIndices).toEqual([0, 1, 2]);
  });

  test("should enumerate NSDictionary with enumerateKeysAndObjectsUsingBlock:", () => {
    // Create a mutable dictionary with some entries
    const dict = NSMutableDictionary.dictionary();
    const key1 = NSString.stringWithUTF8String$("key1");
    const val1 = NSNumber.numberWithInt$(100);
    dict.setObject$forKey$(val1, key1);

    // Enumerate using a block
    const keys: string[] = [];
    const values: number[] = [];

    (dict as _NSDictionary).enumerateKeysAndObjectsUsingBlock$((key: any, obj: any, _stop: any) => {
      keys.push(key.UTF8String());
      values.push(obj.intValue());
    });

    expect(keys).toContain("key1");
    expect(values).toContain(100);
  });

  test("should handle empty array enumeration", () => {
    const arr = NSMutableArray.array();
    let callCount = 0;

    (arr as _NSArray).enumerateObjectsUsingBlock$((_obj: any, _idx: number, _stop: any) => {
      callCount++;
    });

    expect(callCount).toBe(0);
  });

  test("should enumerate multiple dictionary entries", () => {
    const dict = NSMutableDictionary.dictionary();
    dict.setObject$forKey$(NSNumber.numberWithInt$(1), NSString.stringWithUTF8String$("a"));
    dict.setObject$forKey$(NSNumber.numberWithInt$(2), NSString.stringWithUTF8String$("b"));
    dict.setObject$forKey$(NSNumber.numberWithInt$(3), NSString.stringWithUTF8String$("c"));

    const entries: Record<string, number> = {};

    (dict as _NSDictionary).enumerateKeysAndObjectsUsingBlock$((key: any, obj: any, _stop: any) => {
      entries[key.UTF8String()] = obj.intValue();
    });

    expect(Object.keys(entries).length).toBe(3);
    expect(entries["a"]).toBe(1);
    expect(entries["b"]).toBe(2);
    expect(entries["c"]).toBe(3);
  });

  test("should handle block with single element array", () => {
    const arr = NSMutableArray.array();
    arr.addObject$(NSString.stringWithUTF8String$("hello"));

    let receivedString = "";

    (arr as _NSArray).enumerateObjectsUsingBlock$((obj: any, _idx: number, _stop: any) => {
      receivedString = obj.UTF8String();
    });

    expect(receivedString).toBe("hello");
  });
});
