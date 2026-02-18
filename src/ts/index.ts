import {
  LoadLibrary,
  GetClassObject,
  ObjcObject,
  GetPointer,
  FromPointer,
  CreateProtocolImplementation,
  DefineClass,
  CallSuper
} from "./native.js";
import { NobjcNative } from "./native.js";

const customInspectSymbol = Symbol.for("nodejs.util.inspect.custom");
const NATIVE_OBJC_OBJECT = Symbol("nativeObjcObject");

// Module-scope Set for O(1) lookup instead of per-access array with O(n) .includes()
const BUILT_IN_PROPS = new Set([
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
]);

// WeakMap cache for NobjcMethod proxies per object to avoid GC pressure
const methodCache = new WeakMap<NobjcNative.ObjcObject, Map<string, NobjcMethod>>();

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

        // handle other built-in Object.prototype properties (O(1) Set lookup)
        if (BUILT_IN_PROPS.has(methodName)) {
          return Reflect.get(target, methodName);
        }

        if (!(methodName in receiver)) {
          throw new Error(`Method ${methodName} not found on object ${receiver}`);
        }

        // Return cached method proxy if available, otherwise create and cache
        let cache = methodCache.get(object);
        if (!cache) {
          cache = new Map();
          methodCache.set(object, cache);
        }
        let method = cache.get(methodName);
        if (!method) {
          method = NobjcMethod(object, methodName);
          cache.set(methodName, method);
        }
        return method;
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

// Note: This is actually a factory function that returns a callable function
const NobjcMethod = function (object: NobjcNative.ObjcObject, methodName: string): NobjcMethod {
  const selector = NobjcMethodNameToObjcSelector(methodName);

  // Use rest params to avoid Array.from(arguments) + .map() double allocation
  function methodFunc(...args: any[]): any {
    for (let i = 0; i < args.length; i++) {
      args[i] = unwrapArg(args[i]);
    }
    return wrapObjCObjectIfNeeded(object.$msgSend(selector, ...args));
  }
  // Return the function directly — no Proxy wrapper needed (handler was empty)
  return methodFunc as NobjcMethod;
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

/**
 * Method definition for defining a class method.
 */
interface MethodDefinition {
  /**
   * Objective-C type encoding string.
   * Common encodings:
   * - @ = id (object)
   * - : = SEL (selector)
   * - v = void
   * - B = BOOL
   * - q = long long / NSInteger (64-bit)
   * - Q = unsigned long long / NSUInteger (64-bit)
   * - ^@ = id* (pointer to object, e.g., NSError**)
   * - @? = block
   *
   * Example: "@@:@^@" means:
   * - Return: @ (id)
   * - self: @ (id)
   * - _cmd: : (SEL)
   * - arg1: @ (NSArray*)
   * - arg2: ^@ (NSError**)
   */
  types: string;

  /**
   * The JavaScript implementation.
   * Receives (self, ...args) where self is the instance.
   * For NSError** out-params, the arg is an object with { set(error), get() } methods.
   */
  implementation: (self: NobjcObject, ...args: any[]) => any;
}

/**
 * Class definition for creating a new Objective-C class.
 */
interface ClassDefinition {
  /** Name of the new Objective-C class (must be unique in the runtime) */
  name: string;

  /** Superclass - either a class name string or a NobjcObject representing a Class */
  superclass: string | NobjcObject;

  /** Optional: protocols to conform to */
  protocols?: string[];

  /** Instance methods to implement/override */
  methods?: Record<string, MethodDefinition>;

  /** Optional: class methods */
  classMethods?: Record<string, MethodDefinition>;
}

/**
 * API for defining new Objective-C classes at runtime.
 *
 * @example
 * ```typescript
 * // Define a subclass of NSObject
 * const MyClass = NobjcClass.define({
 *   name: "MyClass",
 *   superclass: "NSObject",
 *   protocols: ["NSCopying"],
 *   methods: {
 *     "init": {
 *       types: "@@:",
 *       implementation: (self) => {
 *         return NobjcClass.super(self, "init");
 *       }
 *     },
 *     "myMethod:": {
 *       types: "@@:@",
 *       implementation: (self, arg) => {
 *         console.log("myMethod called with", arg);
 *         return arg;
 *       }
 *     }
 *   }
 * });
 *
 * // Create an instance
 * const instance = MyClass.alloc().init();
 * instance.myMethod$(someArg);
 * ```
 */
class NobjcClass {
  /**
   * Define a new Objective-C class at runtime.
   *
   * @param definition The class definition
   * @returns A NobjcObject representing the new Class (can be used to alloc/init instances)
   *
   * @warning For private methods (like _requestContextWithRequests:error:), you must provide
   * the correct type encoding manually since it cannot be introspected from protocols.
   */
  static define(definition: ClassDefinition): NobjcObject {
    // Convert method implementations to wrap args and unwrap returns
    const nativeDefinition: any = {
      name: definition.name,
      superclass: typeof definition.superclass === "string" ? definition.superclass : unwrapArg(definition.superclass),
      protocols: definition.protocols
    };

    if (definition.methods) {
      nativeDefinition.methods = {};
      for (const [selector, methodDef] of Object.entries(definition.methods)) {
        const normalizedSelector = NobjcMethodNameToObjcSelector(selector);
        nativeDefinition.methods[normalizedSelector] = {
          types: methodDef.types,
          implementation: (nativeSelf: any, ...nativeArgs: any[]) => {
            // Wrap self
            const wrappedSelf = wrapObjCObjectIfNeeded(nativeSelf) as NobjcObject;

            // Wrap args, but preserve out-param objects as-is
            const wrappedArgs = nativeArgs.map((arg) => {
              // Check if it's an out-param object (has 'set' method)
              if (arg && typeof arg === "object" && typeof arg.set === "function") {
                // Keep out-param objects as-is, but wrap the error objects they handle
                return {
                  set: (error: any) => arg.set(unwrapArg(error)),
                  get: () => wrapObjCObjectIfNeeded(arg.get())
                };
              }
              return wrapObjCObjectIfNeeded(arg);
            });

            // Call the user's implementation
            const result = methodDef.implementation(wrappedSelf, ...wrappedArgs);

            // Unwrap the return value
            return unwrapArg(result);
          }
        };
      }
    }

    // Call native DefineClass
    const nativeClass = DefineClass(nativeDefinition);

    // Return wrapped Class object
    return new NobjcObject(nativeClass);
  }

  /**
   * Call the superclass implementation of a method.
   * Use this inside a method implementation to invoke super.
   *
   * @param self The instance (the first argument to your implementation)
   * @param selector The selector string (e.g., "init" or "_requestContextWithRequests:error:")
   * @param args Additional arguments to pass to super
   * @returns The result of the super call
   *
   * @example
   * ```typescript
   * methods: {
   *   "init": {
   *     types: "@@:",
   *     implementation: (self) => {
   *       // Call [super init]
   *       const result = NobjcClass.super(self, "init");
   *       // Do additional setup...
   *       return result;
   *     }
   *   }
   * }
   * ```
   */
  static super(self: NobjcObject, selector: string, ...args: any[]): any {
    const normalizedSelector = NobjcMethodNameToObjcSelector(selector);
    const nativeSelf = unwrapArg(self);
    const unwrappedArgs = args.map(unwrapArg);

    const result = CallSuper(nativeSelf, normalizedSelector, ...unwrappedArgs);
    return wrapObjCObjectIfNeeded(result);
  }
}

export { NobjcLibrary, NobjcObject, NobjcMethod, NobjcProtocol, NobjcClass, getPointer, fromPointer };
