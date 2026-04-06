import { test, expect, describe } from "./test-utils.js";
import { NobjcLibrary, NobjcObject, typedBlock } from "../dist/index.js";

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
  array(): _NSArray;
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
  const NSArray = foundation["NSArray"] as unknown as _NSArrayConstructor;
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

  test("should support typedBlock object signatures for NSArray enumeration", () => {
    const arr = NSMutableArray.array();
    arr.addObject$(NSNumber.numberWithInt$(10));
    arr.addObject$(NSNumber.numberWithInt$(20));

    const collectedValues: number[] = [];
    const collectedIndices: number[] = [];
    const stopValues: any[] = [];

    (arr as _NSArray).enumerateObjectsUsingBlock$(
      typedBlock({ returns: "v", args: ["@", "Q", "^B"] }, (obj: any, idx: number, stop: any) => {
        collectedValues.push(obj.intValue());
        collectedIndices.push(idx);
        stopValues.push(stop);
      })
    );

    expect(collectedValues).toEqual([10, 20]);
    expect(collectedIndices).toEqual([0, 1]);
    expect(stopValues).toEqual([undefined, undefined]);
  });

  test("should support typedBlock full encoding strings for NSDictionary enumeration", () => {
    const dict = NSMutableDictionary.dictionary();
    dict.setObject$forKey$(NSNumber.numberWithInt$(1), NSString.stringWithUTF8String$("a"));
    dict.setObject$forKey$(NSNumber.numberWithInt$(2), NSString.stringWithUTF8String$("b"));

    const entries: Record<string, number> = {};
    const stopValues: any[] = [];

    (dict as _NSDictionary).enumerateKeysAndObjectsUsingBlock$(
      typedBlock("@?<v@?@@^B>", (key: any, obj: any, stop: any) => {
        entries[key.UTF8String()] = obj.intValue();
        stopValues.push(stop);
      })
    );

    expect(entries).toEqual({ a: 1, b: 2 });
    expect(stopValues).toEqual([undefined, undefined]);
  });

  test("should use typedBlock to force object conversion for empty NSArray singletons", () => {
    const outer = NSMutableArray.array();
    outer.addObject$(NSArray.array());

    let receivedCount = -1;

    (outer as _NSArray).enumerateObjectsUsingBlock$(
      typedBlock({ returns: "v", args: ["@", "Q", "^B"] }, (obj: any) => {
        receivedCount = obj.count();
      })
    );

    expect(receivedCount).toBe(0);
  });

  test("should return the same function from typedBlock", () => {
    const fn = (_obj: any, _idx: number, _stop: any) => {};
    expect(typedBlock({ returns: "v", args: ["@", "Q", "^B"] }, fn)).toBe(fn);
  });

  test("should normalize typedBlock signatures when args are omitted", () => {
    const fn = () => {};

    typedBlock({ returns: "v" }, fn);

    expect((fn as any).__nobjcBlockTypeEncoding).toBe("@?<v@?>");
  });

  test("should normalize typedBlock signatures when args are empty", () => {
    const fn = () => {};

    typedBlock({ returns: "@", args: [] }, fn);

    expect((fn as any).__nobjcBlockTypeEncoding).toBe("@?<@@?>");
  });

  test("should preserve valid typedBlock string signatures", () => {
    const fn = () => {};

    typedBlock("@?<v@?@Q^B>", fn);

    expect((fn as any).__nobjcBlockTypeEncoding).toBe("@?<v@?@Q^B>");
  });

  test("should prefer typedBlock types over returns and args", () => {
    const fn = () => {};

    typedBlock(
      {
        types: "@?<q@?@>",
        returns: "v",
        args: ["@", "Q", "^B"]
      },
      fn
    );

    expect((fn as any).__nobjcBlockTypeEncoding).toBe("@?<q@?@>");
  });

  test("should reject invalid typedBlock string signatures", () => {
    expect(() => typedBlock("v@:@", () => {})).toThrow(
      "typedBlock(string, fn) expects a full block type encoding starting with '@?'"
    );
  });

  test("should reject invalid typedBlock types signatures", () => {
    expect(() =>
      typedBlock(
        {
          types: "v@:@",
          returns: "v"
        },
        () => {}
      )
    ).toThrow("typedBlock({ types }, fn) expects a full block type encoding starting with '@?'");
  });
});
