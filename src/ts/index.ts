import { LoadLibrary, GetClassObject, ObjcObject, GetPointer, CreateProtocolImplementation } from "./native.js";
import { NobjcNative } from "./native.js";

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
    const handler: ProxyHandler<NobjcNative.ObjcObject> = {
      has(target, p: string | symbol) {
        // Return true for the special Symbol to enable unwrapping
        if (p === NATIVE_OBJC_OBJECT) return true;
        // guard against other symbols
        if (typeof p === "symbol") return Reflect.has(target, p);
        // toString is always present
        if (p === "toString") return true;
        // check if the object responds to the selector
        return target.$msgSend("respondsToSelector:", NobjcMethodNameToObjcSelector(p.toString())) as boolean;
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
          return () => String(object.$msgSend("description"));
        }
        if (!(methodName in receiver)) {
          throw new Error(`Method ${methodName} not found on object ${receiver}`);
        }
        return new NobjcMethod(object, methodName);
      }
    };
    return new Proxy<NobjcNative.ObjcObject>(object, handler) as unknown as NobjcObject;
  }
}

function unwrapArg(arg: any): any {
  if (arg && typeof arg === "object" && NATIVE_OBJC_OBJECT in arg) {
    return arg[NATIVE_OBJC_OBJECT];
  }
  return arg;
}

class NobjcMethod {
  constructor(object: NobjcNative.ObjcObject, methodName: string) {
    const selector = NobjcMethodNameToObjcSelector(methodName);
    // This cannot be an arrow function because we need to access `arguments`.
    function methodFunc(): any {
      const unwrappedArgs = Array.from(arguments).map(unwrapArg);
      const result = object.$msgSend(selector, ...unwrappedArgs);
      if (typeof result == "object" && result instanceof ObjcObject) {
        return new NobjcObject(result);
      }
      return result;
    }
    const handler: ProxyHandler<any> = {};
    return new Proxy(methodFunc, handler);
  }
}

class NobjcProtocol {
  static implement(protocolName: string, methodImplementations: Record<string, (...args: any[]) => any>): NobjcObject {
    // Convert method names from $ notation to : notation
    const convertedMethods: Record<string, Function> = {};
    for (const [methodName, impl] of Object.entries(methodImplementations)) {
      const selector = NobjcMethodNameToObjcSelector(methodName);
      // Wrap the implementation to unwrap args and wrap return values
      convertedMethods[selector] = function (...args: any[]) {
        const unwrappedArgs = args.map(unwrapArg);
        const result = impl(...unwrappedArgs);
        // If the result is already a NobjcObject, unwrap it to get the native object
        if (result && typeof result === "object" && NATIVE_OBJC_OBJECT in result) {
          return result[NATIVE_OBJC_OBJECT];
        }
        // If the result is a native ObjcObject, return it as-is
        if (typeof result === "object" && result instanceof ObjcObject) {
          return result;
        }
        return result;
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

export { NobjcLibrary, NobjcObject, NobjcMethod, NobjcProtocol, getPointer };
