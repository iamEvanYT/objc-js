import { test, expect } from "bun:test";
import { NobjcLibrary, getPointer } from "../dist/index.js";

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

