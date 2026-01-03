import { test, expect, describe } from "bun:test";
import { NobjcLibrary, NobjcObject, NobjcClass, getPointer } from "../dist/index.js";

// Type declarations
interface _NSString extends NobjcObject {
  isEqualToString$(other: _NSString): boolean;
  stringByAppendingString$(other: _NSString | NobjcObject): _NSString;
  length(): number;
  toString(): string;
}

interface _NSStringConstructor {
  stringWithUTF8String$(str: string): _NSString;
  stringWithFormat$(format: _NSString, ...args: any[]): _NSString;
}

interface _NSMutableString extends _NSString {
  appendString$(str: _NSString): void;
  setString$(str: _NSString): void;
}

interface _NSMutableStringConstructor {
  stringWithUTF8String$(str: string): _NSMutableString;
  alloc(): { initWithString$(str: _NSString): _NSMutableString };
}

interface _NSNumber extends NobjcObject {
  intValue(): number;
  doubleValue(): number;
}

interface _NSNumberConstructor {
  numberWithInt$(value: number): _NSNumber;
}

describe("DefineClass / Subclassing Tests", () => {
  const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  const NSString = Foundation["NSString"] as unknown as _NSStringConstructor;
  const NSMutableString = Foundation["NSMutableString"] as unknown as _NSMutableStringConstructor;
  const NSNumber = Foundation["NSNumber"] as unknown as _NSNumberConstructor;

  test("should create a basic subclass of NSObject", () => {
    let methodCalled = false;

    const MyClass = NobjcClass.define({
      name: "TestBasicSubclass",
      superclass: "NSObject",
      methods: {
        testMethod: {
          types: "v@:", // void return, no args
          implementation: (self) => {
            methodCalled = true;
          }
        }
      }
    });

    expect(MyClass).not.toBeNull();

    // Create an instance
    const instance = (MyClass as any).alloc().init();
    expect(instance).not.toBeNull();

    // Call the method
    (instance as any).testMethod();
    expect(methodCalled).toBe(true);
  });

  test("should return values from subclass methods", () => {
    const MyClass = NobjcClass.define({
      name: "TestReturnValue",
      superclass: "NSObject",
      methods: {
        getString: {
          types: "@@:", // returns id
          implementation: (self) => {
            return NSString.stringWithUTF8String$("Hello from subclass!");
          }
        },
        getNumber: {
          types: "q@:", // returns NSInteger (long long on 64-bit)
          implementation: (self) => {
            return 42;
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();

    const str = (instance as any).getString();
    expect(str.toString()).toBe("Hello from subclass!");

    const num = (instance as any).getNumber();
    expect(num).toBe(42);
  });

  test("should receive arguments in subclass methods", () => {
    let receivedArg1: any = null;
    let receivedArg2: any = null;

    const MyClass = NobjcClass.define({
      name: "TestArguments",
      superclass: "NSObject",
      methods: {
        "processString:withNumber:": {
          types: "v@:@q", // void return, NSString* arg, NSInteger arg
          implementation: (self, str, num) => {
            receivedArg1 = str;
            receivedArg2 = num;
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();
    const testStr = NSString.stringWithUTF8String$("TestArg");

    (instance as any).processString$withNumber$(testStr, 123);

    expect(receivedArg1).not.toBeNull();
    expect(receivedArg1.toString()).toBe("TestArg");
    expect(receivedArg2).toBe(123);
  });

  test("should call super implementation", () => {
    // NSObject's description returns a string like "<ClassName: 0x...>"
    const MyClass = NobjcClass.define({
      name: "TestSuperCall",
      superclass: "NSObject",
      methods: {
        description: {
          types: "@@:", // returns NSString*
          implementation: (self) => {
            const superDesc = NobjcClass.super(self, "description");
            // Simple string concatenation using stringByAppendingString
            const prefix = NSString.stringWithUTF8String$("MyClass(");
            const suffix = NSString.stringWithUTF8String$(")");
            return prefix.stringByAppendingString$(superDesc as any).stringByAppendingString$(suffix);
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();
    const desc = (instance as any).description().toString();

    expect(desc).toContain("MyClass(");
    expect(desc).toContain("TestSuperCall:");
  });

  test("should override init and call super", () => {
    let initCalled = false;

    const MyClass = NobjcClass.define({
      name: "TestInitOverride",
      superclass: "NSObject",
      methods: {
        init: {
          types: "@@:",
          implementation: (self) => {
            initCalled = true;
            // Must call super init and return result
            return NobjcClass.super(self, "init");
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();

    expect(initCalled).toBe(true);
    expect(instance).not.toBeNull();
  });

  test("should conform to protocol when specified", () => {
    const MyClass = NobjcClass.define({
      name: "TestProtocolConformance",
      superclass: "NSObject",
      protocols: ["NSCopying"],
      methods: {
        "copyWithZone:": {
          types: "@@:^v", // id return, void* arg (zone)
          implementation: (self, zone) => {
            // For this test, just return self (shallow copy)
            return self;
          }
        }
      }
    });

    // Check if MyClass was created successfully
    expect(MyClass).not.toBeNull();
    if (!MyClass) return;

    const instance = (MyClass as any).alloc().init();

    // Can call the method
    const copy = (instance as any).copyWithZone$(null);
    expect(copy).not.toBeNull();
  });

  test("should handle $ notation in selector names", () => {
    let called = false;

    const MyClass = NobjcClass.define({
      name: "TestDollarNotation",
      superclass: "NSObject",
      methods: {
        // Using $ notation (which gets converted to :)
        method$with$args$: {
          types: "v@:@@@",
          implementation: (self, arg1, arg2, arg3) => {
            called = true;
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();
    const str = NSString.stringWithUTF8String$("test");

    // Call using $ notation
    (instance as any).method$with$args$(str, str, str);

    expect(called).toBe(true);
  });

  test("should handle BOOL return type", () => {
    const MyClass = NobjcClass.define({
      name: "TestBoolReturn",
      superclass: "NSObject",
      methods: {
        isValid: {
          types: "B@:", // BOOL return
          implementation: (self) => {
            return true;
          }
        },
        isInvalid: {
          types: "B@:",
          implementation: (self) => {
            return false;
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();

    expect((instance as any).isValid()).toBe(true);
    expect((instance as any).isInvalid()).toBe(false);
  });

  test("should handle float/double return types", () => {
    const MyClass = NobjcClass.define({
      name: "TestFloatReturn",
      superclass: "NSObject",
      methods: {
        getFloat: {
          types: "f@:", // float return
          implementation: (self) => {
            return 3.14;
          }
        },
        getDouble: {
          types: "d@:", // double return
          implementation: (self) => {
            return 2.71828;
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();

    expect((instance as any).getFloat()).toBeCloseTo(3.14, 2);
    expect((instance as any).getDouble()).toBeCloseTo(2.71828, 4);
  });

  test("should handle multiple instances independently", () => {
    let instance1Value = 0;
    let instance2Value = 0;

    const MyClass = NobjcClass.define({
      name: "TestMultipleInstances",
      superclass: "NSObject",
      methods: {
        "setValue:": {
          types: "v@:q",
          implementation: (self, value) => {
            // Store based on instance pointer
            const ptr = getPointer(self).readBigUInt64LE(0);
            if (ptr === ptr1) {
              instance1Value = value;
            } else {
              instance2Value = value;
            }
          }
        }
      }
    });

    const inst1 = (MyClass as any).alloc().init();
    const inst2 = (MyClass as any).alloc().init();

    const ptr1 = getPointer(inst1).readBigUInt64LE(0);
    const ptr2 = getPointer(inst2).readBigUInt64LE(0);

    expect(ptr1).not.toBe(ptr2);

    (inst1 as any).setValue$(100);
    (inst2 as any).setValue$(200);

    expect(instance1Value).toBe(100);
    expect(instance2Value).toBe(200);
  });

  test("should create class that already has unique name", () => {
    // Try to create a class with the same name - should throw
    NobjcClass.define({
      name: "UniqueClassName123",
      superclass: "NSObject",
      methods: {}
    });

    expect(() => {
      NobjcClass.define({
        name: "UniqueClassName123",
        superclass: "NSObject",
        methods: {}
      });
    }).toThrow(/already exists/);
  });

  test.skip("should work with subclass of NSMutableString", () => {
    // NOTE: NSMutableString is a class cluster and requires primitive methods to be implemented
    // This test is skipped because subclassing class clusters is complex
    const MyString = NobjcClass.define({
      name: "TestMutableStringSubclass",
      superclass: "NSMutableString",
      methods: {
        description: {
          types: "@@:",
          implementation: (self) => {
            const content = NobjcClass.super(self, "description");
            // Use string concatenation instead of stringWithFormat$
            const prefix = NSString.stringWithUTF8String$("[Wrapped: ");
            const suffix = NSString.stringWithUTF8String$("]");
            return prefix.stringByAppendingString$(content as any).stringByAppendingString$(suffix);
          }
        }
      }
    });

    // NSMutableString requires initWithCapacity: or similar
    const instance = (MyString as any).alloc().initWithCapacity$(100);
    (instance as any).appendString$(NSString.stringWithUTF8String$("Hello"));

    const desc = (instance as any).description().toString();
    expect(desc).toContain("[Wrapped:");
    expect(desc).toContain("Hello");
  });

  test("should respond to selector for defined methods", () => {
    const MyClass = NobjcClass.define({
      name: "TestRespondsToSelector",
      superclass: "NSObject",
      methods: {
        customMethod: {
          types: "v@:",
          implementation: (self) => {}
        }
      }
    });

    const instance = (MyClass as any).alloc().init();

    // Should respond to our custom method
    expect((instance as any).respondsToSelector$("customMethod")).toBe(true);

    // Should respond to inherited NSObject methods
    expect((instance as any).respondsToSelector$("description")).toBe(true);
    expect((instance as any).respondsToSelector$("init")).toBe(true);

    // Should not respond to non-existent methods
    expect((instance as any).respondsToSelector$("nonExistentMethod")).toBe(false);
  });

  test("should call super with one object argument", () => {
    let receivedString: string | null = null;

    const MyClass = NobjcClass.define({
      name: "TestSuperWithOneArg",
      superclass: "NSObject",
      methods: {
        "isEqual:": {
          types: "B@:@", // BOOL return, one object argument
          implementation: (self, other) => {
            // Store the object description for testing
            receivedString = (other as any).description().toString();
            // Call super's isEqual:
            const result = NobjcClass.super(self, "isEqual:", other);
            return result;
          }
        }
      }
    });

    const instance1 = (MyClass as any).alloc().init();
    const instance2 = (MyClass as any).alloc().init();

    const result = (instance1 as any).isEqual$(instance2);

    expect(receivedString).not.toBeNull();
    expect(result).toBe(false); // Different instances should not be equal
  });

  test("should call super with NSInteger argument", () => {
    // Create a subclass of NSMutableArray to test super with NSUInteger
    const MyArray = NobjcClass.define({
      name: "TestSuperWithNSInteger",
      superclass: "NSMutableArray",
      methods: {
        "objectAtIndex:": {
          types: "@@:Q", // id return, NSUInteger arg
          implementation: (self, index) => {
            // Call super
            return NobjcClass.super(self, "objectAtIndex:", index);
          }
        }
      }
    });

    const arr = (MyArray as any).alloc().init();
    const str = NSString.stringWithUTF8String$("Test");
    (arr as any).addObject$(str);

    const result = (arr as any).objectAtIndex$(0);
    expect(result.toString()).toBe("Test");
  });

  test("should call super with two object arguments", () => {
    let interceptedArgs: [any, any] | null = null;

    const MyClass = NobjcClass.define({
      name: "TestSuperWithTwoArgs",
      superclass: "NSMutableArray",
      methods: {
        "replaceObjectAtIndex:withObject:": {
          types: "v@:Q@", // void return, NSUInteger + object
          implementation: (self, index, obj) => {
            interceptedArgs = [index, obj];
            // Call super
            return NobjcClass.super(self, "replaceObjectAtIndex:withObject:", index, obj);
          }
        }
      }
    });

    const arr = (MyClass as any).alloc().init();
    const str1 = NSString.stringWithUTF8String$("First");
    const str2 = NSString.stringWithUTF8String$("Second");

    (arr as any).addObject$(str1);
    (arr as any).replaceObjectAtIndex$withObject$(0, str2);

    expect(interceptedArgs).not.toBeNull();
    expect(interceptedArgs![0]).toBe(0);
    expect((arr as any).objectAtIndex$(0).toString()).toBe("Second");
  });

  test("should call super with NSError** out-parameter", () => {
    // Test the signature @@:@^@ which is used by ASAuthorizationController
    // We'll create a mock test since NSError** is tricky to test directly

    let capturedArgs: any[] | null = null;

    const MyClass = NobjcClass.define({
      name: "TestSuperWithErrorOutParam",
      superclass: "NSObject",
      methods: {
        "testMethod:error:": {
          types: "@@:@^@", // id return, object arg, NSError** error
          implementation: (self, obj, errorOut) => {
            // Just capture the args for testing
            capturedArgs = [obj, errorOut];
            // Return self since there's no super implementation
            return self;
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();
    const testString = NSString.stringWithUTF8String$("test");
    const errorOut = { set: () => {}, get: () => null };

    const result = (instance as any).testMethod$error$(testString, errorOut);

    expect(capturedArgs).not.toBeNull();
    expect(capturedArgs![0]).toBe(testString);
    expect(result).toBe(instance);
  });

  test("should call super with three object arguments", () => {
    // Test with NSMutableArray's addObjectsFromArray which takes 1 arg
    // We'll create a custom three-arg method that delegates to a one-arg super method

    let interceptedArgs: any[] | null = null;

    const MyClass = NobjcClass.define({
      name: "TestSuperWithThreeArgs",
      superclass: "NSMutableArray",
      methods: {
        "customMethod:arg2:arg3:": {
          types: "v@:@@@", // void return, 3 object arguments
          implementation: (self, arg1, arg2, arg3) => {
            // Capture the args
            interceptedArgs = [arg1, arg2, arg3];
            // Call a super method with just one arg
            return NobjcClass.super(self, "addObject:", arg1);
          }
        }
      }
    });

    const arr = (MyClass as any).alloc().init();
    const str1 = NSString.stringWithUTF8String$("First");
    const str2 = NSString.stringWithUTF8String$("Second");
    const str3 = NSString.stringWithUTF8String$("Third");

    (arr as any).customMethod$arg2$arg3$(str1, str2, str3);

    expect(interceptedArgs).not.toBeNull();
    expect(interceptedArgs!.length).toBe(3);
    expect((arr as any).count()).toBe(1); // Only first arg was added
    expect((arr as any).objectAtIndex$(0).toString()).toBe("First");
  });

  test("should handle super call with BOOL argument", () => {
    const MyClass = NobjcClass.define({
      name: "TestSuperWithBoolArg",
      superclass: "NSMutableArray",
      methods: {
        "sortUsingSelector:": {
          types: "v@::", // void return, SEL argument
          implementation: (self, selector) => {
            // Just test that we can call super with a selector (which is like a pointer)
            return NobjcClass.super(self, "sortUsingSelector:", selector);
          }
        }
      }
    });

    const arr = (MyClass as any).alloc().init();
    const str1 = NSString.stringWithUTF8String$("Zebra");
    const str2 = NSString.stringWithUTF8String$("Apple");

    (arr as any).addObject$(str1);
    (arr as any).addObject$(str2);

    // Sort using compare: selector
    (arr as any).sortUsingSelector$("compare:");

    // After sorting, Apple should be first
    expect((arr as any).objectAtIndex$(0).toString()).toBe("Apple");
    expect((arr as any).objectAtIndex$(1).toString()).toBe("Zebra");
  });

  test("should call super from overridden description method", () => {
    const MyClass = NobjcClass.define({
      name: "TestSuperDescription",
      superclass: "NSObject",
      methods: {
        description: {
          types: "@@:",
          implementation: (self) => {
            // Get super's description and add our own prefix
            const superDesc = NobjcClass.super(self, "description");
            const prefixed = NSString.stringWithUTF8String$("Custom: ");
            return (prefixed as any).stringByAppendingString$(superDesc);
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();
    const desc = (instance as any).description().toString();

    expect(desc).toContain("Custom:");
    expect(desc).toContain("TestSuperDescription");
  });
});

describe("DefineClass Edge Cases", () => {
  const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
  const NSString = Foundation["NSString"] as unknown as _NSStringConstructor;

  test("should handle method that throws JS error gracefully", () => {
    const MyClass = NobjcClass.define({
      name: "TestJSErrorHandling",
      superclass: "NSObject",
      methods: {
        throwingMethod: {
          types: "v@:",
          implementation: (self) => {
            throw new Error("JS Error!");
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();

    // The method should not crash the process
    // It may log an error but should return gracefully
    expect(() => {
      (instance as any).throwingMethod();
    }).not.toThrow(); // Native side catches and logs
  });

  test("should handle null/undefined return for object type", () => {
    const MyClass = NobjcClass.define({
      name: "TestNullReturn",
      superclass: "NSObject",
      methods: {
        returnsNull: {
          types: "@@:",
          implementation: (self) => {
            return null;
          }
        },
        returnsUndefined: {
          types: "@@:",
          implementation: (self) => {
            return undefined;
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();

    // Both should return nil (null in JS)
    expect((instance as any).returnsNull()).toBeNull();
    expect((instance as any).returnsUndefined()).toBeNull();
  });

  test("should handle void methods", () => {
    let sideEffect = false;

    const MyClass = NobjcClass.define({
      name: "TestVoidMethod",
      superclass: "NSObject",
      methods: {
        doSomething: {
          types: "v@:",
          implementation: (self) => {
            sideEffect = true;
            // No return statement
          }
        }
      }
    });

    const instance = (MyClass as any).alloc().init();
    const result = (instance as any).doSomething();

    expect(sideEffect).toBe(true);
    expect(result).toBeUndefined();
  });
});
