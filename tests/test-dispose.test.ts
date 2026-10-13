import { test, expect, describe } from "./test-utils.js";
import { NobjcLibrary, NobjcObject, dispose, fromPointer, getPointer } from "../dist/index.js";

interface _NSMutableArray extends NobjcObject {
  addObject$(obj: NobjcObject): void;
  count(): number;
  retainCount(): number;
  enumerateObjectsUsingBlock$(block: (obj: NobjcObject, idx: number, stop: any) => void): void;
}
interface _NSMutableArrayConstructor {
  array(): _NSMutableArray;
}
interface _NSStringConstructor {
  stringWithUTF8String$(str: string): NobjcObject;
}

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSMutableArray = foundation["NSMutableArray"] as unknown as _NSMutableArrayConstructor;
const NSString = foundation["NSString"] as unknown as _NSStringConstructor;

// A second wrapper of the same object, to observe it after the first is disposed
function otherWrapper(obj: NobjcObject): _NSMutableArray {
  return fromPointer(getPointer(obj)) as _NSMutableArray;
}

describe("dispose", () => {
  test("releases the wrapper's reference immediately", () => {
    const array = NSMutableArray.array();
    const observer = otherWrapper(array);
    const before = observer.retainCount();

    dispose(array);

    expect(observer.retainCount()).toBe(before - 1);
  });

  test("rejects use of the disposed wrapper", () => {
    const array = NSMutableArray.array();
    dispose(array);

    expect(() => array.count()).toThrow("Objective-C object has been disposed");
    expect(() => getPointer(array)).toThrow("Objective-C object has been disposed");
  });

  test("rejects passing a disposed object to Objective-C", () => {
    const value = NSString.stringWithUTF8String$("hello");
    const array = NSMutableArray.array();
    dispose(value);

    expect(() => array.addObject$(value)).toThrow("Objective-C object has been disposed");
    expect(array.count()).toBe(0);
  });

  test("is idempotent", () => {
    const array = NSMutableArray.array();
    const observer = otherWrapper(array);
    const before = observer.retainCount();

    dispose(array);
    dispose(array);

    expect(observer.retainCount()).toBe(before - 1);
  });

  test("does nothing for classes", () => {
    dispose(NSMutableArray as unknown as NobjcObject);

    expect(NSMutableArray.array().count()).toBe(0);
  });

  test("defers the release while a method on the object is running", () => {
    const array = NSMutableArray.array();
    array.addObject$(NSString.stringWithUTF8String$("a"));
    const observer = otherWrapper(array);
    const before = observer.retainCount();
    let countDuringCall = -1;

    array.enumerateObjectsUsingBlock$(() => {
      dispose(array);
      countDuringCall = observer.retainCount();
      expect(() => array.count()).toThrow("Objective-C object has been disposed");
    });

    expect(countDuringCall).toBe(before);
    expect(observer.retainCount()).toBe(before - 1);
  });

  test("throws for non-NobjcObject arguments", () => {
    expect(() => dispose({} as NobjcObject)).toThrow(TypeError);
  });
});
