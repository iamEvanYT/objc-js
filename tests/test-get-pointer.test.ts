import { test, expect } from "./test-utils.js";
import { NobjcLibrary, getPointer, fromPointer } from "../dist/index.js";

test("getPointer returns a Buffer with pointer address", () => {
  // Load Foundation framework
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  // Get NSString class and create a string object
  const NSString = foundation["NSString"];
  const str = NSString.stringWithUTF8String$("Hello, World!");

  // Get the pointer
  const pointerBuffer = getPointer(str);

  // Verify it's a Buffer
  expect(Buffer.isBuffer(pointerBuffer)).toBe(true);

  // Verify it's 8 bytes (64-bit pointer)
  expect(pointerBuffer.length).toBe(8);

  // Read the pointer as a BigInt
  const pointer = pointerBuffer.readBigUInt64LE(0);

  // Verify the pointer is a valid non-zero address
  expect(pointer).toBeGreaterThan(0n);
});

test("getPointer returns different pointers for different objects", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  // Create two different objects
  const NSString = foundation["NSString"];
  const str1 = NSString.stringWithUTF8String$("Object 1");
  const str2 = NSString.stringWithUTF8String$("Object 2");

  // Get their pointers
  const pointer1 = getPointer(str1).readBigUInt64LE(0);
  const pointer2 = getPointer(str2).readBigUInt64LE(0);

  // Verify they're different
  expect(pointer1).not.toBe(pointer2);
});

test("getPointer works with different object types", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  // Test with NSString
  const NSString = foundation["NSString"];
  const str = NSString.stringWithUTF8String$("Test");
  const strPointer = getPointer(str).readBigUInt64LE(0);
  expect(strPointer).toBeGreaterThan(0n);

  // Test with NSArray
  const NSArray = foundation["NSArray"];
  const array = NSArray.array();
  const arrayPointer = getPointer(array).readBigUInt64LE(0);
  expect(arrayPointer).toBeGreaterThan(0n);

  // Test with NSDictionary
  const NSDictionary = foundation["NSDictionary"];
  const dict = NSDictionary.dictionary();
  const dictPointer = getPointer(dict).readBigUInt64LE(0);
  expect(dictPointer).toBeGreaterThan(0n);

  // Verify all pointers are different
  expect(strPointer).not.toBe(arrayPointer);
  expect(strPointer).not.toBe(dictPointer);
  expect(arrayPointer).not.toBe(dictPointer);
});

test("getPointer throws TypeError for non-NobjcObject", () => {
  expect(() => {
    getPointer({} as any);
  }).toThrow(TypeError);

  expect(() => {
    getPointer(null as any);
  }).toThrow(TypeError);

  expect(() => {
    getPointer("string" as any);
  }).toThrow(TypeError);
});

test("fromPointer reconstructs object from Buffer", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
  const NSString = foundation["NSString"];
  const original = NSString.stringWithUTF8String$("Hello, World!");

  // Get the pointer as a Buffer
  const pointerBuffer = getPointer(original);

  // Reconstruct the object from the Buffer
  const reconstructed = fromPointer(pointerBuffer);

  // Verify it's the same object by comparing string values
  expect(reconstructed.toString()).toBe(original.toString());
});

test("fromPointer reconstructs object from BigInt", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
  const NSString = foundation["NSString"];
  const original = NSString.stringWithUTF8String$("Test String");

  // Get the pointer as a BigInt
  const pointer = getPointer(original).readBigUInt64LE(0);

  // Reconstruct the object from the BigInt
  const reconstructed = fromPointer(pointer);

  // Verify it's the same object
  expect(reconstructed.toString()).toBe(original.toString());
});

test("fromPointer round-trip preserves object identity", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
  const NSString = foundation["NSString"];
  const original = NSString.stringWithUTF8String$("Round Trip Test");

  // Round trip: object -> pointer -> object
  const pointer = getPointer(original).readBigUInt64LE(0);
  const restored = fromPointer(pointer);

  // Both should have the same string value
  expect(restored.toString()).toBe(original.toString());

  // Both should have the same pointer
  const originalPtr = getPointer(original).readBigUInt64LE(0);
  const restoredPtr = getPointer(restored).readBigUInt64LE(0);
  expect(restoredPtr).toBe(originalPtr);
});

test("fromPointer works with different object types", () => {
  const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  // Test with NSArray
  const NSArray = foundation["NSArray"];
  const array = NSArray.array();
  const arrayPtr = getPointer(array).readBigUInt64LE(0);
  const restoredArray = fromPointer(arrayPtr);
  expect(restoredArray.count()).toBe(0);

  // Test with NSDictionary
  const NSDictionary = foundation["NSDictionary"];
  const dict = NSDictionary.dictionary();
  const dictPtr = getPointer(dict).readBigUInt64LE(0);
  const restoredDict = fromPointer(dictPtr);
  expect(restoredDict.count()).toBe(0);

  // Test with NSNumber
  const NSNumber = foundation["NSNumber"];
  const num = NSNumber.numberWithInt$(42);
  const numPtr = getPointer(num).readBigUInt64LE(0);
  const restoredNum = fromPointer(numPtr);
  expect(restoredNum.intValue()).toBe(42);
});

test("fromPointer throws Error for null pointer (0n)", () => {
  expect(() => {
    fromPointer(0n);
  }).toThrow(Error);
});

test("fromPointer throws TypeError for invalid Buffer size", () => {
  expect(() => {
    fromPointer(Buffer.alloc(4)); // 4 bytes instead of 8
  }).toThrow(TypeError);

  expect(() => {
    fromPointer(Buffer.alloc(16)); // 16 bytes instead of 8
  }).toThrow(TypeError);
});

test("fromPointer throws TypeError for invalid argument types", () => {
  expect(() => {
    fromPointer("not a pointer" as any);
  }).toThrow(TypeError);

  expect(() => {
    fromPointer(123 as any);
  }).toThrow(TypeError);

  expect(() => {
    fromPointer({} as any);
  }).toThrow(TypeError);
});
