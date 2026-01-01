import { test, expect, describe } from "bun:test";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";

// Type declarations for the Objective-C classes we're testing
interface _NSString extends NobjcObject {
  isEqualToString$(other: _NSString): boolean;
  stringByAppendingString$(other: _NSString): _NSString;
  UTF8String(): string;
}

interface _NSStringConstructor {
  "stringWithUTF8String:"(str: string): _NSString;
}

interface _NSMutableArray extends NobjcObject {
  addObject$(obj: NobjcObject): void;
  count(): number;
  containsObject$(obj: NobjcObject): boolean;
  indexOfObject$(obj: NobjcObject): number;
}

interface _NSMutableArrayConstructor {
  array(): _NSMutableArray;
}

interface _NSMutableDictionary extends NobjcObject {
  setObject$forKey$(value: NobjcObject, key: NobjcObject): void;
  "setObject:forKey:"(value: NobjcObject, key: NobjcObject): void;
  objectForKey$(key: NobjcObject): NobjcObject;
  count(): number;
}

interface _NSMutableDictionaryConstructor {
  dictionary(): _NSMutableDictionary;
}

interface _NSMutableString extends NobjcObject {
  appendString$(str: NobjcObject): void;
  UTF8String(): string;
}

interface _NSMutableStringConstructor {
  "stringWithUTF8String:"(str: string): _NSMutableString;
}

describe("NobjcObject Argument Unwrapping Tests", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  const NSString = foundation["NSString"] as unknown as _NSStringConstructor;
  const NSMutableArray = foundation["NSMutableArray"] as unknown as _NSMutableArrayConstructor;
  const NSMutableDictionary = foundation["NSMutableDictionary"] as unknown as _NSMutableDictionaryConstructor;
  const NSMutableString = foundation["NSMutableString"] as unknown as _NSMutableStringConstructor;

  describe("String comparison", () => {
    test("should compare equal strings correctly", () => {
      const str1 = NSString["stringWithUTF8String:"]("Hello");
      const str2 = NSString["stringWithUTF8String:"]("Hello");
      const isEqual = str1.isEqualToString$(str2);
      expect(isEqual).toBe(true);
    });

    test("should compare different strings correctly", () => {
      const str1 = NSString["stringWithUTF8String:"]("Hello");
      const str3 = NSString["stringWithUTF8String:"]("World");
      const isEqual = str1.isEqualToString$(str3);
      expect(isEqual).toBe(false);
    });
  });

  describe("NSMutableArray operations", () => {
    test("should add objects to array", () => {
      const array = NSMutableArray.array();
      const str1 = NSString["stringWithUTF8String:"]("First");
      const str2 = NSString["stringWithUTF8String:"]("Second");
      const str3 = NSString["stringWithUTF8String:"]("Third");

      array.addObject$(str1);
      array.addObject$(str2);
      array.addObject$(str3);

      expect(array.count()).toBe(3);
    });

    test("should check if array contains objects", () => {
      const array = NSMutableArray.array();
      const str1 = NSString["stringWithUTF8String:"]("First");
      const str2 = NSString["stringWithUTF8String:"]("Second");
      const notInArray = NSString["stringWithUTF8String:"]("NotInArray");

      array.addObject$(str1);
      array.addObject$(str2);

      expect(array.containsObject$(str1)).toBe(true);
      expect(array.containsObject$(str2)).toBe(true);
      expect(array.containsObject$(notInArray)).toBe(false);
    });

    test("should find index of objects", () => {
      const array = NSMutableArray.array();
      const item1 = NSString["stringWithUTF8String:"]("Apple");
      const item2 = NSString["stringWithUTF8String:"]("Banana");
      const item3 = NSString["stringWithUTF8String:"]("Cherry");
      const notFound = NSString["stringWithUTF8String:"]("Durian");

      array.addObject$(item1);
      array.addObject$(item2);
      array.addObject$(item3);

      expect(array.indexOfObject$(item2)).toBe(1);
      // NSNotFound is typically NSIntegerMax
      expect(array.indexOfObject$(notFound)).toBe(9223372036854775807);
    });
  });

  describe("NSMutableDictionary operations", () => {
    test("should set and retrieve objects", () => {
      const dict = NSMutableDictionary.dictionary();
      const keyName = NSString["stringWithUTF8String:"]("name");
      const valueName = NSString["stringWithUTF8String:"]("John");
      const keyAge = NSString["stringWithUTF8String:"]("age");
      const valueAge = NSString["stringWithUTF8String:"]("30");

      dict["setObject:forKey:"](valueName, keyName);
      dict["setObject:forKey:"](valueAge, keyAge);

      const retrievedName = dict.objectForKey$(keyName) as _NSString;
      const retrievedAge = dict.objectForKey$(keyAge) as _NSString;

      expect(retrievedName.UTF8String()).toBe("John");
      expect(retrievedAge.UTF8String()).toBe("30");
    });

    test("should have correct count", () => {
      const dict = NSMutableDictionary.dictionary();
      const keyName = NSString["stringWithUTF8String:"]("name");
      const valueName = NSString["stringWithUTF8String:"]("John");
      const keyAge = NSString["stringWithUTF8String:"]("age");
      const valueAge = NSString["stringWithUTF8String:"]("30");

      dict["setObject:forKey:"](valueName, keyName);
      dict["setObject:forKey:"](valueAge, keyAge);

      expect(dict.count()).toBe(2);
    });
  });

  describe("String concatenation", () => {
    test("should concatenate strings with stringByAppendingString:", () => {
      const hello = NSString["stringWithUTF8String:"]("Hello");
      const world = NSString["stringWithUTF8String:"](" World");
      const concatenated = hello.stringByAppendingString$(world);

      expect(concatenated.UTF8String()).toBe("Hello World");
    });
  });

  describe("Mixed primitive and object arguments", () => {
    test("should append string to mutable string", () => {
      const mutableStr = NSMutableString["stringWithUTF8String:"]("Hello");
      const appendStr = NSString["stringWithUTF8String:"](" World");

      mutableStr.appendString$(appendStr);

      expect(mutableStr.UTF8String()).toBe("Hello World");
    });
  });
});
