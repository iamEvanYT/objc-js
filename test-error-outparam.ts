import { NobjcLibrary, NobjcClass, NobjcObject } from "./dist/index.js";

const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = Foundation.NSString as any;

console.log("Testing ^@ (out-parameter) handling with super calls...\n");

// Create a subclass that overrides a method with an out-parameter
const TestClass = NobjcClass.define({
  name: "TestErrorOutParam",
  superclass: "NSObject",
  methods: {
    // This method mimics the signature of _requestContextWithRequests:error:
    testMethodWithError$: {
      types: "@@:^@", // return id, takes NSError**
      implementation: (self: NobjcObject, errorOut: any) => {
        console.log("✓ testMethodWithError$ called");
        console.log("  errorOut arg:", errorOut);

        // In a real scenario, we might call super here
        // For this test, just return a string
        return NSString.stringWithUTF8String$("success");
      }
    }
  }
});

// Test instantiation
const instance = (TestClass as any).alloc().init();
console.log("✓ Instance created:", instance);

// Call the method
try {
  const result = (instance as any).testMethodWithError$(null);
  console.log("✓ Method call succeeded");
  console.log("  Result:", result.toString());
  console.log("\n✅ Test passed! No crash with ^@ parameter.\n");
} catch (e) {
  console.error("❌ Test failed:", e);
  process.exit(1);
}

// Now test with a super call that has ^@ parameter
console.log("\nTesting super call with ^@ parameter...\n");

// NSFileManager has methods with error out-parameters
const NSFileManager = Foundation.NSFileManager as any;
const fileManager = NSFileManager.defaultManager();

const SubFileManager = NobjcClass.define({
  name: "TestSubFileManager",
  superclass: "NSFileManager",
  methods: {
    // Override a method that has an error out-parameter
    contentsOfDirectoryAtPath$error$: {
      types: "@@:@^@",
      implementation: (self: NobjcObject, path: NobjcObject, errorOut: any) => {
        console.log("✓ Override called");
        console.log("  path:", path.toString());
        console.log("  errorOut:", errorOut);

        // Call super - this is the critical test for our fix
        console.log("  Calling super...");
        const result = NobjcClass.super(self, "contentsOfDirectoryAtPath$error$", path, errorOut);
        console.log("  Super call completed successfully!");

        return result;
      }
    }
  }
});

try {
  const customManager = (SubFileManager as any).alloc().init();
  const tmpPath = NSString.stringWithUTF8String$("/tmp");

  console.log("  Calling contentsOfDirectoryAtPath:error: ...");
  const contents = (customManager as any).contentsOfDirectoryAtPath$error$(tmpPath, null);

  if (contents) {
    const count = (contents as any).count();
    console.log(`  ✓ Got ${count} items in /tmp`);
  }

  console.log("\n✅ Super call with ^@ parameter test passed! No crash.\n");
} catch (e) {
  console.error("❌ Super call test failed:", e);
  process.exit(1);
}

console.log("====================================");
console.log("All tests passed! The fix works correctly.");
console.log("====================================");
