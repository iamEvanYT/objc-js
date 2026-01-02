import {
  LoadLibrary,
  GetClassObject,
  ObjcObject,
  GetPointer,
  FromPointer,
  CreateProtocolImplementation
} from "./native.js";
import { NobjcNative } from "./native.js";

const customInspectSymbol = Symbol.for("nodejs.util.inspect.custom");
const NATIVE_OBJC_OBJECT = Symbol("nativeObjcObject");

class NobjcLibrary {
  [key: string]: NobjcObject;
  constructor(library: string) {
    const handler: ProxyHandler<any> & { wasLoaded: boolean } = {
      wasLoaded: false,
      get(_, className: string) {
        if (!this.wasLoaded) {
          LoadLibrary(library);
          this.wasLoaded = true;
        }
        return new NobjcObject(GetClassObject(className));
      }
    };
    return new Proxy({}, handler);
  }
}

function NobjcMethodNameToObjcSelector(methodName: string): string {
  return methodName.replace(/\$/g, ":");
}
// unused, might be useful for codegen later
function ObjcSelectorToNobjcMethodName(selector: string): string {
  return selector.replace(/:/g, "$");
}

class NobjcObject {
  [key: string]: NobjcMethod;
  constructor(object: NobjcNative.ObjcObject) {
    // Create the proxy handler
    const handler: ProxyHandler<NobjcNative.ObjcObject> = {
      has(target, p: string | symbol) {
        // Return true for the special Symbol to enable unwrapping
        if (p === NATIVE_OBJC_OBJECT) return true;
        // guard against other symbols
        if (typeof p === "symbol") return Reflect.has(target, p);
        // toString is always present
        if (p === "toString") return true;
        // check if the object responds to the selector
        try {
          return target.$msgSend("respondsToSelector:", NobjcMethodNameToObjcSelector(p.toString())) as boolean;
        } catch (e) {
          return false;
        }
      },
      get(target, methodName: string | symbol, receiver: NobjcObject) {
        // Return the underlying native object when Symbol is accessed
        if (methodName === NATIVE_OBJC_OBJECT) {
          return target;
        }

        // guard against symbols
        if (typeof methodName === "symbol") {
          return Reflect.get(object, methodName, receiver);
        }

        // handle toString separately
        if (methodName === "toString") {
          // if the receiver has a UTF8String method, use it to get the string representation
          if ("UTF8String" in receiver) {
            return () => String(object.$msgSend("UTF8String"));
          }
          // Otherwise, use the description method
          return () => String(wrapObjCObjectIfNeeded(object.$msgSend("description")));
        }

        // handle other built-in Object.prototype properties
        const builtInProps = [
          "constructor",
          "valueOf",
          "hasOwnProperty",
          "isPrototypeOf",
          "propertyIsEnumerable",
          "toLocaleString",
          "__proto__",
          "__defineGetter__",
          "__defineSetter__",
          "__lookupGetter__",
          "__lookupSetter__"
        ];
        if (builtInProps.includes(methodName)) {
          return Reflect.get(target, methodName);
        }

        if (!(methodName in receiver)) {
          throw new Error(`Method ${methodName} not found on object ${receiver}`);
        }
        return NobjcMethod(object, methodName);
      }
    };

    // Create the proxy
    const proxy = new Proxy<NobjcNative.ObjcObject>(object, handler) as unknown as NobjcObject;

    // This is used to override the default inspect behavior for the object. (console.log)
    (object as any)[customInspectSymbol] = () => proxy.toString();

    // Return the proxy
    return proxy;
  }
}

function unwrapArg(arg: any): any {
  if (arg && typeof arg === "object" && NATIVE_OBJC_OBJECT in arg) {
    return arg[NATIVE_OBJC_OBJECT];
  }
  return arg;
}

function wrapObjCObjectIfNeeded(result: unknown): unknown {
  if (typeof result == "object" && result instanceof ObjcObject) {
    return new NobjcObject(result);
  }
  return result;
}

interface NobjcMethod {
  (...args: any[]): any;
}

// Note: This is actually a factory function that returns a callable Proxy
const NobjcMethod = function (object: NobjcNative.ObjcObject, methodName: string): NobjcMethod {
  const selector = NobjcMethodNameToObjcSelector(methodName);

  // This cannot be an arrow function because we need to access `arguments`.
  function methodFunc(): any {
    const unwrappedArgs = Array.from(arguments).map(unwrapArg);
    const result = object.$msgSend(selector, ...unwrappedArgs);
    return wrapObjCObjectIfNeeded(result);
  }
  const handler: ProxyHandler<any> = {};
  return new Proxy(methodFunc, handler) as NobjcMethod;
};

class NobjcProtocol {
  static implement(protocolName: string, methodImplementations: Record<string, (...args: any[]) => any>): NobjcObject {
    // Convert method names from $ notation to : notation
    const convertedMethods: Record<string, Function> = {};
    for (const [methodName, impl] of Object.entries(methodImplementations)) {
      const selector = NobjcMethodNameToObjcSelector(methodName);
      // Wrap the implementation to wrap args and unwrap return values
      convertedMethods[selector] = function (...args: any[]) {
        // Wrap native ObjcObject arguments in NobjcObject proxies
        const wrappedArgs = args.map((arg) => {
          return wrapObjCObjectIfNeeded(arg);
        });

        const result = impl(...wrappedArgs);

        // If the result is already a NobjcObject, unwrap it to get the native object
        return unwrapArg(result);
      };
    }

    // Call native implementation
    const nativeObj = CreateProtocolImplementation(protocolName, convertedMethods);

    // Wrap in NobjcObject proxy
    return new NobjcObject(nativeObj);
  }
}

/**
 * Get the raw native pointer for a NobjcObject as a Node Buffer.
 * The pointer is stored in little-endian format (8 bytes on 64-bit macOS).
 *
 * @param obj - The NobjcObject to get the pointer from
 * @returns A Buffer containing the pointer address
 *
 * @example
 * ```typescript
 * const view = window.contentView();
 * const pointerBuffer = getPointer(view);
 * const pointer = pointerBuffer.readBigUInt64LE(0);
 * console.log(`NSView pointer: 0x${pointer.toString(16)}`);
 * ```
 */
function getPointer(obj: NobjcObject): Buffer {
  // Unwrap the NobjcObject to get the native ObjcObject
  if (obj && typeof obj === "object" && NATIVE_OBJC_OBJECT in obj) {
    const nativeObj = (obj as any)[NATIVE_OBJC_OBJECT];
    return GetPointer(nativeObj);
  }
  throw new TypeError("Argument must be a NobjcObject instance");
}

/**
 * Create a NobjcObject from a raw native pointer.
 *
 * @param pointer - A Buffer or BigInt containing the pointer address
 * @returns A NobjcObject wrapping the native object
 *
 * @example
 * ```typescript
 * // From a Buffer
 * const pointerBuffer = getPointer(originalObject);
 * const reconstructed = fromPointer(pointerBuffer);
 *
 * // From a BigInt
 * const pointer = 0x12345678n;
 * const obj = fromPointer(pointer);
 *
 * // Round-trip example
 * const original = NSString.stringWithUTF8String$("Hello");
 * const ptr = getPointer(original).readBigUInt64LE(0);
 * const restored = fromPointer(ptr);
 * console.log(restored.toString()); // "Hello"
 * ```
 *
 * @warning This is unsafe! The pointer must point to a valid Objective-C object.
 * Using an invalid pointer will cause a crash. The object must still be alive
 * (not deallocated) when you call this function.
 */
function fromPointer(pointer: Buffer | bigint): NobjcObject {
  const nativeObj = FromPointer(pointer);
  if (nativeObj === null) {
    throw new Error("Cannot create object from null pointer");
  }
  return new NobjcObject(nativeObj);
}

export { NobjcLibrary, NobjcObject, NobjcMethod, NobjcProtocol, getPointer, fromPointer };
