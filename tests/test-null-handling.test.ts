import { test, expect, describe } from "bun:test";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";

describe("Comprehensive Null/Undefined Handling Tests", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
  const NSString = foundation["NSString"] as any;
  const NSNumber = foundation["NSNumber"] as any;
  const NSMutableDictionary = foundation["NSMutableDictionary"] as any;
  const NSValue = foundation["NSValue"] as any;

  describe("Object type (id) null handling", () => {
    test("should convert null to nil for object arguments", () => {
      const str = NSString["stringWithUTF8String:"]("Hello");

      // isEqualToString: with nil should return false
      const result = str.isEqualToString$(null);
      expect(result).toBe(false);
    });

    test("should convert undefined to nil for object arguments", () => {
      const str = NSString["stringWithUTF8String:"]("Hello");

      // isEqualToString: with nil should return false
      const result = str.isEqualToString$(undefined);
      expect(result).toBe(false);
    });

    test("should handle null in methods with multiple object arguments", () => {
      const dict = NSMutableDictionary.dictionary();

      // objectForKey: with nil should not crash
      const result = dict.objectForKey$(null);
      expect(result).toBeNull();
    });
  });

  describe("Primitive type null handling", () => {
    test("should convert null to 0 for integer arguments", () => {
      // NSNumber numberWithInt: should accept null and treat as 0
      const num = NSNumber["numberWithInt:"](null);
      expect(num.intValue()).toBe(0);
    });

    test("should convert undefined to 0 for integer arguments", () => {
      const num = NSNumber["numberWithInt:"](undefined);
      expect(num.intValue()).toBe(0);
    });

    test("should convert null to 0 for long arguments", () => {
      const num = NSNumber["numberWithLong:"](null);
      expect(num.longValue()).toBe(0);
    });

    test("should convert null to 0 for float arguments", () => {
      const num = NSNumber["numberWithFloat:"](null);
      expect(num.floatValue()).toBe(0);
    });

    test("should convert null to 0 for double arguments", () => {
      const num = NSNumber["numberWithDouble:"](null);
      expect(num.doubleValue()).toBe(0);
    });

    test("should convert null to false for boolean arguments", () => {
      const num = NSNumber["numberWithBool:"](null);
      expect(num.boolValue()).toBe(false);
    });

    test("should convert undefined to false for boolean arguments", () => {
      const num = NSNumber["numberWithBool:"](undefined);
      expect(num.boolValue()).toBe(false);
    });
  });

  describe("String type (C string) null handling", () => {
    test("should convert null to empty string for C string arguments", () => {
      // stringWithUTF8String: with null should create empty string or handle gracefully
      const str = NSString["stringWithUTF8String:"](null);

      // Result should either be empty string or nil
      if (str === null) {
        expect(str).toBeNull();
      } else {
        expect(str.length()).toBe(0);
      }
    });

    test("should convert undefined to empty string for C string arguments", () => {
      const str = NSString["stringWithUTF8String:"](undefined);

      // Result should either be empty string or nil
      if (str === null) {
        expect(str).toBeNull();
      } else {
        expect(str.length()).toBe(0);
      }
    });
  });

  describe("Pointer type null handling", () => {
    test("should convert null to nullptr for pointer arguments", () => {
      // NSData dataWithBytes:length: should accept null pointer
      const NSData = foundation["NSData"] as any;
      const data = NSData["dataWithBytes:length:"](null, 0);

      // Should create empty NSData or nil
      if (data === null) {
        expect(data).toBeNull();
      } else {
        expect(data.length()).toBe(0);
      }
    });

    test("should convert undefined to nullptr for pointer arguments", () => {
      const NSData = foundation["NSData"] as any;
      const data = NSData["dataWithBytes:length:"](undefined, 0);

      // Should create empty NSData or nil
      if (data === null) {
        expect(data).toBeNull();
      } else {
        expect(data.length()).toBe(0);
      }
    });
  });

  describe("Mixed null arguments", () => {
    test("should handle null for multiple different argument types", () => {
      // Test passing null to various argument positions
      const dict = NSMutableDictionary.dictionary();

      // All of these should not crash
      expect(() => {
        dict.objectForKey$(null);
      }).not.toThrow();

      expect(() => {
        const str = NSString["stringWithUTF8String:"]("test");
        str.isEqualToString$(null);
      }).not.toThrow();

      expect(() => {
        NSNumber["numberWithInt:"](null);
      }).not.toThrow();
    });
  });

  describe("Return value null handling", () => {
    test("should return null when Objective-C method returns nil", () => {
      const dict = NSMutableDictionary.dictionary();
      const result = dict.objectForKey$(NSString["stringWithUTF8String:"]("nonexistent"));

      expect(result).toBeNull();
    });

    test("should handle nil return from methods expecting objects", () => {
      const NSArray = foundation["NSArray"] as any;
      const emptyArray = NSArray.array();

      // firstObject on empty array returns nil
      const result = emptyArray.firstObject();
      expect(result).toBeNull();
    });
  });
});
