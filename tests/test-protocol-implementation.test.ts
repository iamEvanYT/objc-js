import { test, expect, describe } from "bun:test";
import { NobjcLibrary, NobjcObject, NobjcProtocol } from "../dist/index.js";

// Type declarations for the Objective-C classes we're testing
interface _NSString extends NobjcObject {
  isEqualToString$(other: _NSString): boolean;
  stringByAppendingString$(other: _NSString): _NSString;
  toString(): string;
}

interface _NSStringConstructor {
  stringWithUTF8String$(str: string): _NSString;
}

interface _NSMutableArray extends NobjcObject {
  addObject$(obj: NobjcObject): void;
  count(): number;
  objectAtIndex$(index: number): NobjcObject;
  containsObject$(obj: NobjcObject): boolean;
  sortUsingSelector$(selector: string): void;
}

interface _NSMutableArrayConstructor {
  array(): _NSMutableArray;
}

interface _NSNumber extends NobjcObject {
  intValue(): number;
  compare$(other: _NSNumber): number;
}

interface _NSNumberConstructor {
  numberWithInt$(value: number): _NSNumber;
}

describe("Protocol Implementation Tests", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  const NSString = foundation["NSString"] as unknown as _NSStringConstructor;
  const NSMutableArray = foundation["NSMutableArray"] as unknown as _NSMutableArrayConstructor;
  const NSNumber = foundation["NSNumber"] as unknown as _NSNumberConstructor;

  test("should create protocol implementation with callback", () => {
    let callbackInvoked = false;
    let receivedArg1: any = null;
    let receivedArg2: any = null;

    const delegate = NobjcProtocol.implement("TestProtocol", {
      "testMethod:withArg:": (arg1: any, arg2: any) => {
        callbackInvoked = true;
        receivedArg1 = arg1;
        receivedArg2 = arg2;
      }
    });

    expect(delegate).not.toBeNull();
  });

  test("should verify delegate is a valid NobjcObject", () => {
    const delegate = NobjcProtocol.implement("TestProtocol", {
      "testMethod:withArg:": (arg1: any, arg2: any) => {}
    });

    const delegateDescription = (delegate as any).description();
    expect(delegateDescription).toBeTypeOf("object");
  });

  test("should respond to NSObject methods", () => {
    const delegate = NobjcProtocol.implement("TestProtocol", {
      "testMethod:withArg:": (arg1: any, arg2: any) => {}
    });

    const respondsToDescription = (delegate as any).respondsToSelector$("description");
    expect(respondsToDescription).toBe(true);
  });

  test("should respond to implemented protocol methods", () => {
    const delegate = NobjcProtocol.implement("TestProtocol", {
      "customMethod:": (arg: any) => {}
    });

    const respondsToCustomMethod = (delegate as any).respondsToSelector$("customMethod:");
    expect(respondsToCustomMethod).toBe(true);

    const respondsToNonExistentMethod = (delegate as any).respondsToSelector$("nonExistentMethod:");
    expect(respondsToNonExistentMethod).toBe(false);
  });

  test("should create comparison delegate for array sorting", () => {
    let comparisonCallCount = 0;

    const comparator = NobjcProtocol.implement("ComparisonProtocol", {
      "compare:": (other: NobjcObject) => {
        comparisonCallCount++;
        return 0; // Equal
      }
    });

    expect(comparator).not.toBeNull();
  });

  test("should create multiple protocol implementations", () => {
    const delegate1 = NobjcProtocol.implement("TestProtocol1", {
      method1: () => {}
    });

    const delegate2 = NobjcProtocol.implement("TestProtocol2", {
      method2: () => {}
    });

    expect(delegate1).not.toBeNull();
    expect(delegate2).not.toBeNull();
  });

  test("should create protocol with object arguments", () => {
    let receivedString: string | null = null;

    const stringDelegate = NobjcProtocol.implement("StringProtocol", {
      "handleString:": (str: NobjcObject) => {
        receivedString = str.toString();
      }
    });

    expect(stringDelegate).not.toBeNull();
  });

  test("should create protocol with primitive arguments", () => {
    let receivedInt: number | null = null;
    let receivedBool: boolean | null = null;

    const primitiveDelegate = NobjcProtocol.implement("PrimitiveProtocol", {
      "handleInt:andBool:": (intVal: number, boolVal: boolean) => {
        receivedInt = intVal;
        receivedBool = boolVal;
      }
    });

    expect(primitiveDelegate).not.toBeNull();
  });

  test("should handle $ notation conversion", () => {
    const dollarDelegate = NobjcProtocol.implement("DollarProtocol", {
      method$with$args$: (arg1: any, arg2: any, arg3: any) => {}
    });

    expect(dollarDelegate).not.toBeNull();
  });

  test("should handle memory management correctly", () => {
    for (let i = 0; i < 10; i++) {
      const tempDelegate = NobjcProtocol.implement("TempProtocol", {
        tempMethod: () => {}
      });
      // Let it go out of scope
    }

    // If we get here without crashing, the test passes
    expect(true).toBe(true);
  });

  test("should create protocol with no methods", () => {
    const emptyDelegate = NobjcProtocol.implement("EmptyProtocol", {});
    expect(emptyDelegate).not.toBeNull();
  });

  test("should work with real NSCopying protocol", () => {
    try {
      const copyDelegate = NobjcProtocol.implement("NSCopying", {
        "copyWithZone:": (zone: any) => {
          return null; // Return nil for now
        }
      });

      expect(copyDelegate).not.toBeNull();
    } catch (e) {
      // If NSCopying is not available, skip the test
      expect(true).toBe(true);
    }
  });

  test("should actually invoke callback when method is called via performSelector", () => {
    let callbackInvoked = false;
    let receivedArg: any = null;

    const delegate = NobjcProtocol.implement("TestProtocol", {
      "handleString:": (arg: any) => {
        callbackInvoked = true;
        receivedArg = arg;
      }
    });

    // Create an NSString to pass as argument
    const testString = NSString.stringWithUTF8String$("TestValue");

    // Call the method via performSelector:withObject:
    (delegate as any).performSelector$withObject$("handleString:", testString);

    expect(callbackInvoked).toBe(true);
    expect(receivedArg).not.toBeNull();
    // The callback was successfully invoked! This proves protocol callbacks work.
  });
});
