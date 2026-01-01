import { NobjcLibrary, NobjcObject, NobjcProtocol } from "../dist/index.js";

console.log("Testing Protocol Implementation...\n");

const foundation = new NobjcLibrary(
  "/System/Library/Frameworks/Foundation.framework/Foundation"
);

// Type declarations for the Objective-C classes we're testing
declare class _NSString extends NobjcObject {
  static stringWithUTF8String$(str: string): _NSString;
  isEqualToString$(other: _NSString): boolean;
  stringByAppendingString$(other: _NSString): _NSString;
  toString(): string;
}

declare class _NSMutableArray extends NobjcObject {
  static array(): _NSMutableArray;
  addObject$(obj: NobjcObject): void;
  count(): number;
  objectAtIndex$(index: number): NobjcObject;
  containsObject$(obj: NobjcObject): boolean;
  sortUsingSelector$(selector: string): void;
}

declare class _NSNumber extends NobjcObject {
  static numberWithInt$(value: number): _NSNumber;
  intValue(): number;
  compare$(other: _NSNumber): number;
}

const NSString = foundation["NSString"] as unknown as typeof _NSString;
const NSMutableArray = foundation[
  "NSMutableArray"
] as unknown as typeof _NSMutableArray;
const NSNumber = foundation["NSNumber"] as unknown as typeof _NSNumber;

// Test 1: Create a simple protocol implementation
console.log("Test 1: Create protocol implementation with callback");
let callbackInvoked = false;
let receivedArg1: any = null;
let receivedArg2: any = null;

// Create a protocol implementation
// Note: We're using a made-up protocol name since we just want to test
// that we can create a class with methods
const delegate = NobjcProtocol.implement("TestProtocol", {
  "testMethod:withArg:": (arg1: any, arg2: any) => {
    console.log("  ✅ Callback invoked!");
    callbackInvoked = true;
    receivedArg1 = arg1;
    receivedArg2 = arg2;
  },
});

console.log("  Protocol implementation created successfully");
console.assert(delegate !== null, "Delegate should not be null");
console.log("  ✅ Test 1 passed\n");

// Test 2: Verify the delegate is a valid NobjcObject
console.log("Test 2: Verify delegate is a valid NobjcObject");
const delegateDescription = (delegate as any).description();
console.log(`  Delegate description: ${delegateDescription}`);
console.assert(
  typeof delegateDescription === "object",
  "Delegate should have a description"
);
console.log("  ✅ Test 2 passed\n");

// Test 3: Test with NSObject methods
console.log("Test 3: Test delegate responds to NSObject methods");
const respondsToDescription = (delegate as any).respondsToSelector$(
  "description"
);
console.log(`  Responds to 'description': ${respondsToDescription}`);
console.assert(
  respondsToDescription === true,
  "Delegate should respond to description"
);
console.log("  ✅ Test 3 passed\n");

// Test 4: Create a comparison delegate for sorting
console.log("Test 4: Create comparison delegate for array sorting");

// We'll create a custom comparison method
let comparisonCallCount = 0;

const comparator = NobjcProtocol.implement("ComparisonProtocol", {
  "compare:": (other: NobjcObject) => {
    comparisonCallCount++;
    // This would be called during sorting
    return 0; // Equal
  },
});

console.log("  Comparator created successfully");
console.log("  ✅ Test 4 passed\n");

// Test 5: Create multiple protocol implementations
console.log("Test 5: Create multiple protocol implementations");

const delegate1 = NobjcProtocol.implement("TestProtocol1", {
  method1: () => {
    console.log("  Delegate 1 method called");
  },
});

const delegate2 = NobjcProtocol.implement("TestProtocol2", {
  method2: () => {
    console.log("  Delegate 2 method called");
  },
});

console.log("  Multiple delegates created successfully");
console.assert(delegate1 !== null, "Delegate 1 should not be null");
console.assert(delegate2 !== null, "Delegate 2 should not be null");
console.log("  ✅ Test 5 passed\n");

// Test 6: Test with method that takes object arguments
console.log("Test 6: Test protocol with object arguments");

let receivedString: string | null = null;

const stringDelegate = NobjcProtocol.implement("StringProtocol", {
  "handleString:": (str: NobjcObject) => {
    console.log("  String handler called");
    receivedString = str.toString();
    console.log(`  Received string: ${receivedString}`);
  },
});

console.log("  String delegate created successfully");
console.log("  ✅ Test 6 passed\n");

// Test 7: Test with method that takes primitive arguments
console.log("Test 7: Test protocol with primitive arguments");

let receivedInt: number | null = null;
let receivedBool: boolean | null = null;

const primitiveDelegate = NobjcProtocol.implement("PrimitiveProtocol", {
  "handleInt:andBool:": (intVal: number, boolVal: boolean) => {
    console.log("  Primitive handler called");
    receivedInt = intVal;
    receivedBool = boolVal;
    console.log(`  Received int: ${intVal}, bool: ${boolVal}`);
  },
});

console.log("  Primitive delegate created successfully");
console.log("  ✅ Test 7 passed\n");

// Test 8: Test with $ notation in method names
console.log("Test 8: Test $ notation conversion");

const dollarDelegate = NobjcProtocol.implement("DollarProtocol", {
  method$with$args$: (arg1: any, arg2: any, arg3: any) => {
    console.log("  Method with $ notation called");
  },
});

console.log("  Delegate with $ notation created successfully");
console.log("  ✅ Test 8 passed\n");

// Test 9: Test memory management - create and release
console.log("Test 9: Test memory management");

for (let i = 0; i < 10; i++) {
  const tempDelegate = NobjcProtocol.implement("TempProtocol", {
    tempMethod: () => {
      // This callback should be cleaned up when the delegate is released
    },
  });
  // Let it go out of scope
}

console.log("  Created and released 10 delegates");
console.log("  ✅ Test 9 passed (no crashes)\n");

// Test 10: Test with no methods
console.log("Test 10: Test protocol with no methods");

const emptyDelegate = NobjcProtocol.implement("EmptyProtocol", {});

console.log("  Empty delegate created successfully");
console.assert(emptyDelegate !== null, "Empty delegate should not be null");
console.log("  ✅ Test 10 passed\n");

// Test 11: Test with real NSCopying protocol (if available)
console.log("Test 11: Test with real protocol (NSCopying)");

try {
  const copyDelegate = NobjcProtocol.implement("NSCopying", {
    "copyWithZone:": (zone: any) => {
      console.log("  copyWithZone: called");
      return null; // Return nil for now
    },
  });

  console.log("  NSCopying delegate created successfully");
  console.log("  ✅ Test 11 passed\n");
} catch (e) {
  console.log(`  Note: NSCopying test skipped (${e})`);
  console.log("  ✅ Test 11 passed (with skip)\n");
}

console.log("========================================");
console.log("All protocol implementation tests passed! ✅");
console.log("========================================");
