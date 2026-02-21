import { test, expect, describe } from "bun:test";
import { NobjcLibrary, NobjcObject, callFunction, callVariadicFunction } from "../dist/index.js";

// Type declarations for the Objective-C classes we're testing
interface _NSString extends NobjcObject {
  UTF8String(): string;
  length(): number;
  toString(): string;
}

interface _NSStringConstructor {
  stringWithUTF8String$(str: string): _NSString;
}

describe("C Function Calling Tests", () => {
  const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
  const NSString = Foundation.NSString as unknown as _NSStringConstructor;

  describe("callFunction — inferred types (no options)", () => {
    test("should call NSLog with inferred void return and arg type", () => {
      const message = NSString.stringWithUTF8String$("test-call-function: NSLog works!");
      // Simplest form: void return, arg type inferred as @ (NobjcObject)
      expect(() => callFunction("NSLog", message)).not.toThrow();
    });

    test("void return should return undefined", () => {
      const message = NSString.stringWithUTF8String$("test-call-function: void return test");
      const result = callFunction("NSLog", message);
      expect(result).toBeUndefined();
    });

    test("should throw for non-existent function", () => {
      expect(() => callFunction("ThisFunctionDoesNotExist123")).toThrow(/not found/);
    });
  });

  describe("callFunction — with { returns } option", () => {
    test("should call NSHomeDirectory() with no args", () => {
      const homeDir = callFunction("NSHomeDirectory", { returns: "@" });
      expect(homeDir).toBeDefined();
      expect(homeDir.toString()).toContain("/Users/");
    });

    test("should call NSTemporaryDirectory()", () => {
      const tmpDir = callFunction("NSTemporaryDirectory", { returns: "@" });
      expect(tmpDir).toBeDefined();
      expect(tmpDir.toString().length).toBeGreaterThan(0);
    });

    test("should call NSUserName()", () => {
      const userName = callFunction("NSUserName", { returns: "@" });
      expect(userName).toBeDefined();
      expect(userName.toString().length).toBeGreaterThan(0);
    });

    test("should call NSFullUserName()", () => {
      const fullName = callFunction("NSFullUserName", { returns: "@" });
      expect(fullName).toBeDefined();
      expect(fullName.toString().length).toBeGreaterThan(0);
    });

    test("should call NSStringFromClass with inferred arg type", () => {
      // NSStringFromClass(Class cls) -> NSString*
      // cls is a NobjcObject, inferred as "@" (works because Class is-an id)
      const cls = Foundation.NSString;
      const className = callFunction("NSStringFromClass", { returns: "@" }, cls);
      expect(className).toBeDefined();
      expect(className.toString()).toBe("NSString");
    });

    test("should call NSClassFromString with inferred arg type", () => {
      // NSClassFromString(NSString *aClassName) -> Class
      const className = NSString.stringWithUTF8String$("NSArray");
      const cls = callFunction("NSClassFromString", { returns: "#" }, className);
      expect(cls).toBeDefined();
    });

    test("should call NSSelectorFromString with inferred arg type", () => {
      // NSSelectorFromString(NSString *aSelectorName) -> SEL
      const selectorName = NSString.stringWithUTF8String$("init");
      const result = callFunction("NSSelectorFromString", { returns: ":" }, selectorName);
      expect(result).toBeDefined();
      expect(result).toBe("init");
    });

    test("should throw for wrong argument count", () => {
      expect(() => callFunction("NSHomeDirectory", { returns: "@" }, "extra")).toThrow();
    });
  });

  describe("callFunction — with explicit { args } option", () => {
    test("should call NSStringFromSelector with SEL arg type", () => {
      // NSStringFromSelector(SEL sel) -> NSString*
      // SEL args need explicit ":" type since strings default to "@" (NSString)
      const result = callFunction("NSStringFromSelector", { returns: "@", args: [":"] }, "stringWithUTF8String:");
      expect(result).toBeDefined();
      expect(result.toString()).toBe("stringWithUTF8String:");
    });

    test("should call NSStringFromClass with explicit # arg type", () => {
      // Explicit Class type encoding (also works with inferred @ since Class is-an id)
      const cls = Foundation.NSString;
      const className = callFunction("NSStringFromClass", { returns: "@", args: ["#"] }, cls);
      expect(className).toBeDefined();
      expect(className.toString()).toBe("NSString");
    });
  });

  describe("callFunction — with { types } combined string", () => {
    test("should parse combined type string: return + arg", () => {
      // types: "@:" means return @, arg :
      const result = callFunction("NSStringFromSelector", { types: "@:" }, "description");
      expect(result).toBeDefined();
      expect(result.toString()).toBe("description");
    });

    test("should parse combined type string: return only", () => {
      // types: "@" means return @, no arg types (inferred)
      const homeDir = callFunction("NSHomeDirectory", { types: "@" });
      expect(homeDir).toBeDefined();
      expect(homeDir.toString()).toContain("/Users/");
    });
  });

  describe("callVariadicFunction — inferred types", () => {
    test("should call NSLog with format + one arg (variadic)", () => {
      const format = NSString.stringWithUTF8String$("test-variadic: Hello, %@!");
      const name = NSString.stringWithUTF8String$("World");
      // fixedArgCount = 1, arg types inferred as @
      expect(() => callVariadicFunction("NSLog", 1, format, name)).not.toThrow();
    });

    test("should call NSLog with format + multiple args (variadic)", () => {
      const format = NSString.stringWithUTF8String$("test-variadic: %@ + %@ = %@");
      const a = NSString.stringWithUTF8String$("1");
      const b = NSString.stringWithUTF8String$("2");
      const c = NSString.stringWithUTF8String$("3");
      expect(() => callVariadicFunction("NSLog", 1, format, a, b, c)).not.toThrow();
    });
  });

  describe("callVariadicFunction — with explicit types", () => {
    test("should call NSLog with format + integer arg", () => {
      const format = NSString.stringWithUTF8String$("test-variadic: number = %d");
      // Need explicit "i" for the integer variadic arg (numbers default to "d")
      expect(() => callVariadicFunction("NSLog", { args: ["@", "i"] }, 1, format, 42)).not.toThrow();
    });
  });
});
