import { test, expect, describe } from "bun:test";
import { NobjcLibrary, NobjcObject } from "../dist/index.js";

describe("Struct Support Tests", () => {
  const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
  const AppKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");

  describe("Struct Arguments", () => {
    test("should pass NSRange struct to NSString substringWithRange:", () => {
      const NSString = Foundation.NSString as any;
      const str = NSString.stringWithUTF8String$("Hello, World!");

      // NSRange is {location, length} — {_NSRange=QQ} (two unsigned long long)
      const range = { location: 7, length: 5 };
      const substring = str.substringWithRange$(range);
      expect(substring.UTF8String()).toBe("World");
    });

    test("should pass NSRange struct as array", () => {
      const NSString = Foundation.NSString as any;
      const str = NSString.stringWithUTF8String$("Hello, World!");

      // NSRange as flat array [location, length]
      const range = [7, 5];
      const substring = str.substringWithRange$(range);
      expect(substring.UTF8String()).toBe("World");
    });

    test("should pass CGRect struct to NSWindow initWithContentRect:styleMask:backing:defer:", () => {
      const NSWindow = AppKit.NSWindow as any;

      const rect = {
        origin: { x: 100, y: 100 },
        size: { width: 400, height: 300 }
      };

      // NSWindowStyleMaskTitled(1) | NSWindowStyleMaskClosable(2)
      const styleMask = 1 | 2;
      // NSBackingStoreBuffered = 2
      const backingStore = 2;

      const window = NSWindow.alloc().initWithContentRect$styleMask$backing$defer$(
        rect,
        styleMask,
        backingStore,
        false
      );
      expect(window).toBeDefined();

      // Verify the window was created with the right properties
      const title = (Foundation.NSString as any).stringWithUTF8String$("Test Window");
      window.setTitle$(title);
      const retrievedTitle = window.title();
      expect(retrievedTitle.UTF8String()).toBe("Test Window");
    });

    test("should pass CGPoint struct to NSValue", () => {
      const NSValue = Foundation.NSValue as any;

      // valueWithPoint: expects NSPoint which is CGPoint = {CGPoint=dd}
      const point = { x: 42.5, y: 99.0 };
      const value = NSValue.valueWithPoint$(point);
      expect(value).toBeDefined();
    });

    test("should pass CGSize struct to NSValue", () => {
      const NSValue = Foundation.NSValue as any;

      // valueWithSize: expects NSSize which is CGSize = {CGSize=dd}
      const size = { width: 640.0, height: 480.0 };
      const value = NSValue.valueWithSize$(size);
      expect(value).toBeDefined();
    });
  });

  describe("Struct Return Values", () => {
    test("should return NSRange struct from NSString rangeOfString:", () => {
      const NSString = Foundation.NSString as any;
      const str = NSString.stringWithUTF8String$("Hello, World!");
      const searchStr = NSString.stringWithUTF8String$("World");

      const range = str.rangeOfString$(searchStr);
      expect(range).toBeDefined();
      expect(typeof range).toBe("object");
      expect(range.location).toBe(7);
      expect(range.length).toBe(5);
    });

    test("should return NSRange with NSNotFound when string not found", () => {
      const NSString = Foundation.NSString as any;
      const str = NSString.stringWithUTF8String$("Hello, World!");
      const searchStr = NSString.stringWithUTF8String$("Foo");

      const range = str.rangeOfString$(searchStr);
      expect(range).toBeDefined();
      // NSNotFound is typically the max value of NSUInteger
      expect(range.location).not.toBe(0);
      expect(range.length).toBe(0);
    });

    test("should return CGPoint struct from NSValue pointValue", () => {
      const NSValue = Foundation.NSValue as any;

      const point = { x: 42.5, y: 99.0 };
      const value = NSValue.valueWithPoint$(point);
      const retrieved = value.pointValue();

      expect(retrieved).toBeDefined();
      expect(typeof retrieved).toBe("object");
      expect(retrieved.x).toBeCloseTo(42.5, 5);
      expect(retrieved.y).toBeCloseTo(99.0, 5);
    });

    test("should return CGSize struct from NSValue sizeValue", () => {
      const NSValue = Foundation.NSValue as any;

      const size = { width: 640.0, height: 480.0 };
      const value = NSValue.valueWithSize$(size);
      const retrieved = value.sizeValue();

      expect(retrieved).toBeDefined();
      expect(typeof retrieved).toBe("object");
      expect(retrieved.width).toBeCloseTo(640.0, 5);
      expect(retrieved.height).toBeCloseTo(480.0, 5);
    });

    test("should return CGRect struct from NSValue rectValue", () => {
      const NSValue = Foundation.NSValue as any;

      const rect = {
        origin: { x: 10.0, y: 20.0 },
        size: { width: 300.0, height: 200.0 }
      };
      const value = NSValue.valueWithRect$(rect);
      const retrieved = value.rectValue();

      expect(retrieved).toBeDefined();
      expect(typeof retrieved).toBe("object");
      expect(retrieved.origin).toBeDefined();
      expect(retrieved.origin.x).toBeCloseTo(10.0, 5);
      expect(retrieved.origin.y).toBeCloseTo(20.0, 5);
      expect(retrieved.size).toBeDefined();
      expect(retrieved.size.width).toBeCloseTo(300.0, 5);
      expect(retrieved.size.height).toBeCloseTo(200.0, 5);
    });

    test("should return CGRect from NSWindow frame", () => {
      const NSWindow = AppKit.NSWindow as any;

      const rect = {
        origin: { x: 100, y: 200 },
        size: { width: 800, height: 600 }
      };

      const window = NSWindow.alloc().initWithContentRect$styleMask$backing$defer$(rect, 1 | 2, 2, false);

      const frame = window.frame();
      expect(frame).toBeDefined();
      expect(typeof frame).toBe("object");
      expect(frame.origin).toBeDefined();
      expect(frame.size).toBeDefined();
      // The frame might not match exactly due to title bar, but size should
      // be close and origin should be in the expected range
      expect(frame.size.width).toBeCloseTo(800, 0);
      expect(frame.size.height).toBeGreaterThanOrEqual(600);
    });
  });

  describe("Struct Roundtrip", () => {
    test("should roundtrip CGRect through NSValue", () => {
      const NSValue = Foundation.NSValue as any;

      const original = {
        origin: { x: 1.5, y: 2.5 },
        size: { width: 100.25, height: 200.75 }
      };

      const value = NSValue.valueWithRect$(original);
      const roundtripped = value.rectValue();

      expect(roundtripped.origin.x).toBeCloseTo(1.5, 10);
      expect(roundtripped.origin.y).toBeCloseTo(2.5, 10);
      expect(roundtripped.size.width).toBeCloseTo(100.25, 10);
      expect(roundtripped.size.height).toBeCloseTo(200.75, 10);
    });

    test("should roundtrip CGPoint through NSValue", () => {
      const NSValue = Foundation.NSValue as any;

      const original = { x: -50.5, y: 1234.0 };
      const value = NSValue.valueWithPoint$(original);
      const roundtripped = value.pointValue();

      expect(roundtripped.x).toBeCloseTo(-50.5, 10);
      expect(roundtripped.y).toBeCloseTo(1234.0, 10);
    });

    test("should roundtrip CGSize through NSValue", () => {
      const NSValue = Foundation.NSValue as any;

      const original = { width: 1920.0, height: 1080.0 };
      const value = NSValue.valueWithSize$(original);
      const roundtripped = value.sizeValue();

      expect(roundtripped.width).toBeCloseTo(1920.0, 10);
      expect(roundtripped.height).toBeCloseTo(1080.0, 10);
    });

    test("should roundtrip NSRange through NSValue", () => {
      const NSValue = Foundation.NSValue as any;

      const original = { location: 42, length: 100 };
      const value = NSValue.valueWithRange$(original);
      const roundtripped = value.rangeValue();

      expect(roundtripped.location).toBe(42);
      expect(roundtripped.length).toBe(100);
    });
  });
});
