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

import { NobjcLibrary, NobjcObject } from "../dist/index.js";

const Foundation = new NobjcLibrary(
  "/System/Library/Frameworks/Foundation.framework/Foundation"
);

declare class _NSString extends NobjcObject {
  static stringWithUTF8String$(str: string): _NSString;
  UTF8String(): string;
  length(): number;
  toString(): string;
}

const NSString = Foundation.NSString as unknown as typeof _NSString;

// Test with many iterations to increase chance of catching use-after-free
const TEST_ITERATIONS = 1000;

console.log(`Testing NSString creation ${TEST_ITERATIONS} times...`);

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

console.log(`\nResults: ${successes} passed, ${failures} failed`);

if (failures > 0) {
  console.error("\n❌ TEST FAILED: String argument lifetime bug detected!");
  process.exit(1);
} else {
  console.log("\n✅ TEST PASSED: All strings created and retrieved correctly.");
  process.exit(0);
}
