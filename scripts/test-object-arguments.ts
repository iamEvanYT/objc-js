import { NobjcLibrary, NobjcObject } from "../dist/index.js";

console.log("Testing NobjcObject argument unwrapping...\n");

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
  containsObject$(obj: NobjcObject): boolean;
  indexOfObject$(obj: NobjcObject): number;
}

declare class _NSMutableDictionary extends NobjcObject {
  static dictionary(): _NSMutableDictionary;
  setObject$forKey$(value: NobjcObject, key: NobjcObject): void;
  "setObject:forKey:"(value: NobjcObject, key: NobjcObject): void;
  objectForKey$(key: NobjcObject): NobjcObject;
  count(): number;
}

declare class _NSMutableString extends NobjcObject {
  static stringWithUTF8String$(str: string): _NSMutableString;
  appendString$(str: NobjcObject): void;
  toString(): string;
}

// Test 1: String comparison with isEqualToString:
console.log("Test 1: String comparison");
const NSString = foundation["NSString"] as unknown as typeof _NSString;
const str1 = NSString["stringWithUTF8String:"]("Hello");
const str2 = NSString["stringWithUTF8String:"]("Hello");
const str3 = NSString["stringWithUTF8String:"]("World");

const isEqual1 = str1.isEqualToString$(str2);
const isEqual2 = str1.isEqualToString$(str3);

console.log(`  str1.isEqualToString$(str2): ${isEqual1} (expected: true)`);
console.log(`  str1.isEqualToString$(str3): ${isEqual2} (expected: false)`);
console.assert(isEqual1 === true, "str1 should equal str2");
console.assert(isEqual2 === false, "str1 should not equal str3");
console.log("  ✅ String comparison test passed\n");

// Test 2: NSMutableArray operations
console.log("Test 2: NSMutableArray operations");
const NSMutableArray = foundation[
  "NSMutableArray"
] as unknown as typeof _NSMutableArray;
const array = NSMutableArray.array();

const arrayStr1 = NSString["stringWithUTF8String:"]("First");
const arrayStr2 = NSString["stringWithUTF8String:"]("Second");
const arrayStr3 = NSString["stringWithUTF8String:"]("Third");

array.addObject$(arrayStr1);
array.addObject$(arrayStr2);
array.addObject$(arrayStr3);

const arrayCount = array.count();
console.log(`  Array count: ${arrayCount} (expected: 3)`);
console.assert(arrayCount === 3, "Array should contain 3 objects");

const containsFirst = array.containsObject$(arrayStr1);
const containsSecond = array.containsObject$(arrayStr2);
const notInArray = NSString["stringWithUTF8String:"]("NotInArray");
const containsNotInArray = array.containsObject$(notInArray);

console.log(`  Array contains "First": ${containsFirst} (expected: true)`);
console.log(`  Array contains "Second": ${containsSecond} (expected: true)`);
console.log(
  `  Array contains "NotInArray": ${containsNotInArray} (expected: false)`
);
console.assert(containsFirst === true, "Array should contain arrayStr1");
console.assert(containsSecond === true, "Array should contain arrayStr2");
console.assert(
  containsNotInArray === false,
  "Array should not contain notInArray"
);
console.log("  ✅ NSMutableArray operations test passed\n");

// Test 3: NSMutableDictionary operations
console.log("Test 3: NSMutableDictionary operations");
const NSMutableDictionary = foundation[
  "NSMutableDictionary"
] as unknown as typeof _NSMutableDictionary;
const dict = NSMutableDictionary.dictionary();

const keyName = NSString["stringWithUTF8String:"]("name");
const valueName = NSString["stringWithUTF8String:"]("John");
const keyAge = NSString["stringWithUTF8String:"]("age");
const valueAge = NSString["stringWithUTF8String:"]("30");

dict["setObject:forKey:"](valueName, keyName);
dict["setObject:forKey:"](valueAge, keyAge);

const retrievedName = dict.objectForKey$(keyName);
const retrievedAge = dict.objectForKey$(keyAge);

console.log(`  Retrieved name: ${retrievedName.toString()} (expected: John)`);
console.log(`  Retrieved age: ${retrievedAge.toString()} (expected: 30)`);
console.assert(
  retrievedName.toString() === "John",
  "Retrieved name should be John"
);
console.assert(retrievedAge.toString() === "30", "Retrieved age should be 30");

const dictCount = dict.count();
console.log(`  Dictionary count: ${dictCount} (expected: 2)`);
console.assert(dictCount === 2, "Dictionary should contain 2 key-value pairs");
console.log("  ✅ NSMutableDictionary operations test passed\n");

// Test 4: String concatenation with stringByAppendingString:
console.log("Test 4: String concatenation");
const hello = NSString["stringWithUTF8String:"]("Hello");
const world = NSString["stringWithUTF8String:"](" World");
const concatenated = hello.stringByAppendingString$(world);

console.log(
  `  Concatenated: "${concatenated.toString()}" (expected: "Hello World")`
);
console.assert(
  concatenated.toString() === "Hello World",
  "Concatenated string should be 'Hello World'"
);
console.log("  ✅ String concatenation test passed\n");

// Test 5: NSArray indexOfObject:
console.log("Test 5: NSArray indexOfObject:");
const searchArray = NSMutableArray.array();
const item1 = NSString["stringWithUTF8String:"]("Apple");
const item2 = NSString["stringWithUTF8String:"]("Banana");
const item3 = NSString["stringWithUTF8String:"]("Cherry");

searchArray.addObject$(item1);
searchArray.addObject$(item2);
searchArray.addObject$(item3);

const indexOfBanana = searchArray.indexOfObject$(item2);
const notFound = NSString["stringWithUTF8String:"]("Durian");
const indexOfDurian = searchArray.indexOfObject$(notFound);

console.log(`  Index of "Banana": ${indexOfBanana} (expected: 1)`);
console.log(
  `  Index of "Durian": ${indexOfDurian} (expected: 9223372036854775807)`
);
console.assert(indexOfBanana === 1, "Index of Banana should be 1");
// NSNotFound is typically NSIntegerMax
console.assert(
  indexOfDurian === 9223372036854775807,
  "Index of Durian should be NSNotFound"
);
console.log("  ✅ NSArray indexOfObject test passed\n");

// Test 6: Mixed primitive and object arguments
console.log("Test 6: Mixed primitive and object arguments");
const NSMutableString = foundation[
  "NSMutableString"
] as unknown as typeof _NSMutableString;
const mutableStr = NSMutableString["stringWithUTF8String:"]("Hello");
const appendStr = NSString["stringWithUTF8String:"](" World");

// appendString: takes an object argument
mutableStr.appendString$(appendStr);
console.log(
  `  Mutable string: "${mutableStr.toString()}" (expected: "Hello World")`
);
console.assert(
  mutableStr.toString() === "Hello World",
  "Mutable string should be 'Hello World'"
);
console.log("  ✅ Mixed arguments test passed\n");

console.log("========================================");
console.log("All tests passed! ✅");
console.log("========================================");
