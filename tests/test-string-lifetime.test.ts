import { test, expect, describe } from "bun:test";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";

/**
 * Test for string argument lifetime bug fix.
 *
 * This test verifies that string arguments passed to Objective-C methods
 * remain valid until after the method invocation completes.
 *
 * The bug: When passing a string to a method like `stringWithUTF8String:`,
 * the std::string containing the argument data was being destroyed before
 * `[invocation invoke]` was called, leaving a dangling pointer.
 *
 * The fix: Store all arguments in a vector that outlives the invoke call.
 */

describe("String Lifetime Tests", () => {
  const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

  interface _NSString extends NobjcObject {
    stringWithUTF8String$(str: string): _NSString;
    UTF8String(): string;
    length(): number;
    toString(): string;
  }

  const NSString = Foundation.NSString as unknown as _NSString;

  const TEST_ITERATIONS = 1000;

  test(`should create NSString ${TEST_ITERATIONS} times without use-after-free`, () => {
    let failures = 0;
    let successes = 0;

    for (let i = 0; i < TEST_ITERATIONS; i++) {
      const testString = `Test string #${i} with some padding to make it longer`;

      const nsString = NSString.stringWithUTF8String$(testString);

      // Check if the result is null (the bug symptom)
      if (nsString == null) {
        failures++;
        console.error(`FAIL: Iteration ${i} - stringWithUTF8String$ returned null`);
        continue;
      }

      // Verify the string content matches
      const retrieved = nsString.UTF8String();
      if (retrieved !== testString) {
        failures++;
        console.error(`FAIL: Iteration ${i} - String mismatch:`);
        console.error(`  Expected: "${testString}"`);
        console.error(`  Got: "${retrieved}"`);
        continue;
      }

      // Verify the length is correct
      const expectedLength = Buffer.from(testString, "utf8").length;
      const actualLength = nsString.length();
      if (actualLength !== expectedLength) {
        failures++;
        console.error(`FAIL: Iteration ${i} - Length mismatch:`);
        console.error(`  Expected: ${expectedLength}`);
        console.error(`  Got: ${actualLength}`);
        continue;
      }

      successes++;
    }

    expect(failures).toBe(0);
    expect(successes).toBe(TEST_ITERATIONS);
  });

  test("should correctly handle string content retrieval", () => {
    const testString = "Test string with special chars: 你好世界 🌍";
    const nsString = NSString.stringWithUTF8String$(testString);

    expect(nsString).not.toBeNull();
    expect(nsString.UTF8String()).toBe(testString);
  });

  test("should correctly handle string length calculation", () => {
    const testString = "Hello";
    const nsString = NSString.stringWithUTF8String$(testString);
    const expectedLength = Buffer.from(testString, "utf8").length;

    expect(nsString.length()).toBe(expectedLength);
  });
});
