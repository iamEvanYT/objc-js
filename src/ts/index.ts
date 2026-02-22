import {
  LoadLibrary,
  GetClassObject,
  ObjcObject,
  GetPointer,
  FromPointer,
  CreateProtocolImplementation,
  DefineClass,
  CallSuper,
  CallFunction
} from "./native.js";
import { NobjcNative } from "./native.js";

const customInspectSymbol = Symbol.for("nodejs.util.inspect.custom");
const NATIVE_OBJC_OBJECT = Symbol("nativeObjcObject");

// WeakMap side-channel for O(1) proxy → native object lookup (bypasses Proxy traps)
const nativeObjectMap = new WeakMap<object, NobjcNative.ObjcObject>();

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
    const classCache = new Map<string, NobjcObject>();
    const handler: ProxyHandler<any> & { wasLoaded: boolean } = {
      wasLoaded: false,
      get(_, className: string) {
        let cls = classCache.get(className);
        if (cls) return cls;
        if (!this.wasLoaded) {
          LoadLibrary(library);
          this.wasLoaded = true;
        }
        const classObject = GetClassObject(className);
        if (classObject === undefined) {
          // Class not found. Make sure the class exists before trying to access it.
          return undefined;
        }
        cls = new NobjcObject(classObject);
        classCache.set(className, cls);
        return cls;
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
          return target.$respondsToSelector(NobjcMethodNameToObjcSelector(p.toString())) as boolean;
        } catch (e) {
          return false;
        }
      },
      get(target, methodName: string | symbol, receiver: NobjcObject) {
        // Return the underlying native object when Symbol is accessed
        if (methodName === NATIVE_OBJC_OBJECT) {
          return target;
        }

        // Handle customInspectSymbol in get trap instead of mutating native object
        // (avoids hidden class transition that deoptimizes V8 inline caches)
        if (methodName === customInspectSymbol) {
          return () => proxy.toString();
        }

        // guard against symbols
        if (typeof methodName === "symbol") {
          return Reflect.get(object, methodName, receiver);
        }

        // handle toString separately (cached to avoid repeated closure allocation and FFI check)
        if (methodName === "toString") {
          let cache = methodCache.get(object);
          if (!cache) {
            cache = new Map();
            methodCache.set(object, cache);
          }
          let fn = cache.get("toString");
          if (!fn) {
            // Check directly on native object to avoid triggering proxy has trap
            const hasUTF8 = target.$respondsToSelector("UTF8String") as boolean;
            fn = (hasUTF8
              ? () => String(object.$msgSend("UTF8String"))
              : () => String(wrapObjCObjectIfNeeded(object.$msgSend("description")))) as unknown as NobjcMethod;
            cache.set("toString", fn);
          }
          return fn;
        }

        // handle other built-in Object.prototype properties (O(1) Set lookup)
        if (BUILT_IN_PROPS.has(methodName)) {
          return Reflect.get(target, methodName);
        }

        // Return cached method proxy if available, otherwise create and cache
        let cache = methodCache.get(object);
        if (!cache) {
          cache = new Map();
          methodCache.set(object, cache);
        }
        let method = cache.get(methodName);
        if (!method) {
          // Check respondsToSelector on cache miss only, directly on native
          // object (avoids triggering proxy 'has' trap which would be a second FFI call)
          const selector = NobjcMethodNameToObjcSelector(methodName);
          if (!target.$respondsToSelector(selector)) {
            // special case since JS checks for `.then` on Promise objects
            if (methodName === "then") return undefined;

            // Otherwise, throw an error
            throw new Error(`Method ${methodName} not found on object`);
          }
          method = NobjcMethod(object, methodName);
          cache.set(methodName, method);
        }
        return method;
      }
    };

    // Create the proxy
    const proxy = new Proxy<NobjcNative.ObjcObject>(object, handler) as unknown as NobjcObject;

    // Store proxy → native mapping in WeakMap for O(1) unwrap (bypasses Proxy traps)
    nativeObjectMap.set(proxy as unknown as object, object);

    // Return the proxy
    return proxy;
  }
}

function unwrapArg(arg: any): any {
  if (arg && typeof arg === "object") {
    return nativeObjectMap.get(arg) ?? arg;
  }
  // Wrap function arguments so that when called from native (e.g., as ObjC blocks),
  // the native ObjcObject args are automatically wrapped in NobjcObject proxies.
  if (typeof arg === "function") {
    const wrapped = function (...nativeArgs: any[]) {
      for (let i = 0; i < nativeArgs.length; i++) {
        nativeArgs[i] = wrapObjCObjectIfNeeded(nativeArgs[i]);
      }
      return unwrapArg(arg(...nativeArgs));
    };
    // Preserve the original function's .length so the native layer can read it
    // (used to infer block parameter count when extended encoding is unavailable)
    Object.defineProperty(wrapped, "length", { value: arg.length });
    return wrapped;
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

  // H2: Cache SEL + method signature natively via $prepareSend.
  // This avoids re-registering the selector, respondsToSelector:, and
  // method signature lookup on every call.
  const handle = object.$prepareSend(selector);

  // Fast paths for 0-3 args avoid rest param array allocation + spread overhead
  function methodFunc(...args: any[]): any {
    switch (args.length) {
      case 0:
        return wrapObjCObjectIfNeeded(object.$msgSendPrepared(handle));
      case 1:
        return wrapObjCObjectIfNeeded(object.$msgSendPrepared(handle, unwrapArg(args[0])));
      case 2:
        return wrapObjCObjectIfNeeded(object.$msgSendPrepared(handle, unwrapArg(args[0]), unwrapArg(args[1])));
      case 3:
        return wrapObjCObjectIfNeeded(
          object.$msgSendPrepared(handle, unwrapArg(args[0]), unwrapArg(args[1]), unwrapArg(args[2]))
        );
      default:
        for (let i = 0; i < args.length; i++) {
          args[i] = unwrapArg(args[i]);
        }
        return wrapObjCObjectIfNeeded(object.$msgSendPrepared(handle, ...args));
    }
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
        // Wrap native ObjcObject arguments in NobjcObject proxies (in-place to avoid allocation)
        for (let i = 0; i < args.length; i++) {
          args[i] = wrapObjCObjectIfNeeded(args[i]);
        }

        const result = impl(...args);

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
  // Unwrap the NobjcObject to get the native ObjcObject via WeakMap
  const nativeObj = nativeObjectMap.get(obj as unknown as object);
  if (nativeObj) {
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

            // Wrap args in-place to avoid allocation (preserve out-param objects)
            for (let i = 0; i < nativeArgs.length; i++) {
              const arg = nativeArgs[i];
              if (arg && typeof arg === "object" && typeof arg.set === "function") {
                nativeArgs[i] = {
                  set: (error: any) => arg.set(unwrapArg(error)),
                  get: () => wrapObjCObjectIfNeeded(arg.get())
                };
              } else {
                nativeArgs[i] = wrapObjCObjectIfNeeded(arg);
              }
            }

            // Call the user's implementation
            const result = methodDef.implementation(wrappedSelf, ...nativeArgs);

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
    // Mutate args in-place to avoid allocation
    for (let i = 0; i < args.length; i++) {
      args[i] = unwrapArg(args[i]);
    }

    const result = CallSuper(nativeSelf, normalizedSelector, ...args);
    return wrapObjCObjectIfNeeded(result);
  }
}

/**
 * Options for specifying C function type information.
 * Only needed when type inference isn't sufficient (e.g., non-void return, SEL/integer args).
 */
interface CallFunctionOptions {
  /** Return type encoding. Defaults to "v" (void). Common: "@" (object), "v" (void), "d" (double), "q" (int64). */
  returns?: string;
  /** Argument type encodings. If omitted, types are inferred from JS values. */
  args?: string[];
  /** Combined type string (return type + arg types). Alternative to returns/args. E.g. "@#" = returns @, arg #. */
  types?: string;
}

/**
 * Parse a combined type encoding string into individual type encodings.
 * Handles multi-character encodings: ^v (pointer), {CGRect=dd} (struct), etc.
 */
function parseTypeEncodings(typeStr: string): string[] {
  const result: string[] = [];
  let i = 0;
  while (i < typeStr.length) {
    const start = i;
    const ch = typeStr[i];
    if (ch === "{" || ch === "[" || ch === "(") {
      const close = ch === "{" ? "}" : ch === "[" ? "]" : ")";
      let depth = 1;
      i++;
      while (i < typeStr.length && depth > 0) {
        if (typeStr[i] === ch) depth++;
        else if (typeStr[i] === close) depth--;
        i++;
      }
    } else if (ch === "^") {
      i++;
      if (i < typeStr.length) {
        if (typeStr[i] === "{" || typeStr[i] === "[" || typeStr[i] === "(") {
          // Pointer to compound type — parse the inner type
          const inner = parseTypeEncodings(typeStr.substring(i));
          i += inner[0]?.length ?? 1;
        } else {
          i++; // pointer to simple type (^v, ^@, etc.)
        }
      }
    } else {
      i++;
    }
    result.push(typeStr.substring(start, i));
  }
  return result;
}

/**
 * Infer the ObjC type encoding for a JS argument value.
 * - NobjcObject / object → "@" (id)
 * - string → "@" (auto-converted to NSString by native code)
 * - boolean → "B" (BOOL)
 * - number → "d" (double/CGFloat)
 * - null/undefined → "@" (nil)
 *
 * Note: numbers always infer as "d" (double). For integer params (NSInteger, etc.),
 * specify the type explicitly via { args: ["q"] } or { types: "..." }.
 */
function inferArgType(arg: any): string {
  if (arg === null || arg === undefined) return "@";
  if (typeof arg === "boolean") return "B";
  if (typeof arg === "number") return "d";
  return "@";
}

/**
 * Check if a value is a CallFunctionOptions object (not a NobjcObject or struct).
 */
function isCallOptions(value: any): value is CallFunctionOptions {
  if (value === null || value === undefined || typeof value !== "object") return false;
  if (nativeObjectMap.has(value)) return false; // It's a NobjcObject proxy
  return "returns" in value || "types" in value || "args" in value;
}

/**
 * Resolve return type and arg types from options + values.
 */
function resolveTypes(options: CallFunctionOptions | null, args: any[]): { returnType: string; argTypes: string[] } {
  if (options?.types) {
    const encodings = parseTypeEncodings(options.types);
    const returnType = encodings[0] || "v";
    const explicitArgTypes = encodings.slice(1);
    return {
      returnType,
      argTypes: explicitArgTypes.length > 0 ? explicitArgTypes : args.map(inferArgType)
    };
  }
  return {
    returnType: options?.returns || "v",
    argTypes: options?.args || args.map(inferArgType)
  };
}

/**
 * Call a C function by name.
 *
 * The framework containing the function must be loaded first (e.g., via `new NobjcLibrary(...)`).
 * Uses `dlsym` to look up the function symbol and `libffi` to call it with the correct ABI.
 *
 * Argument types are inferred from JS values by default:
 * - NobjcObject → `@` (id)
 * - string → `@` (auto-converted to NSString)
 * - boolean → `B` (BOOL)
 * - number → `d` (double/CGFloat)
 * - null → `@` (nil)
 *
 * Return type defaults to `"v"` (void). Pass an options object to specify return/arg types.
 *
 * @param name - The function name (e.g., "NSLog", "NSHomeDirectory")
 * @param optionsOrFirstArg - Either a CallFunctionOptions object or the first function argument
 * @param args - The actual arguments to pass to the function
 * @returns The return value converted to a JavaScript type, or undefined for void functions
 *
 * @example
 * ```typescript
 * import { NobjcLibrary, callFunction } from "objc-js";
 *
 * const Foundation = new NobjcLibrary(
 *   "/System/Library/Frameworks/Foundation.framework/Foundation"
 * );
 * const NSString = Foundation.NSString;
 *
 * // Void function — simplest form, no options needed
 * const msg = NSString.stringWithUTF8String$("Hello!");
 * callFunction("NSLog", msg);
 *
 * // Function that returns a value — specify { returns }
 * const homeDir = callFunction("NSHomeDirectory", { returns: "@" });
 * console.log(homeDir.toString());
 *
 * // Explicit arg types when inference isn't enough
 * const selName = callFunction("NSStringFromSelector", { returns: "@", args: [":"] }, "description");
 *
 * // Combined type string shorthand (return + args)
 * const className = callFunction("NSStringFromClass", { types: "@#" }, NSString);
 * ```
 */
function callFunction(name: string, ...rest: any[]): any {
  let options: CallFunctionOptions | null = null;
  let args: any[];

  if (rest.length > 0 && isCallOptions(rest[0])) {
    options = rest[0];
    args = rest.slice(1);
  } else {
    args = rest;
  }

  const { returnType, argTypes } = resolveTypes(options, args);

  // Unwrap NobjcObject proxies to native objects
  for (let i = 0; i < args.length; i++) {
    args[i] = unwrapArg(args[i]);
  }
  const result = CallFunction(name, returnType, argTypes, argTypes.length, ...args);
  return wrapObjCObjectIfNeeded(result);
}

/**
 * Call a variadic C function by name.
 *
 * Correctly handles variadic calling conventions (important on Apple Silicon / ARM64
 * where variadic args go on the stack while fixed args go in registers).
 *
 * @param name - The function name (e.g., "NSLog")
 * @param optionsOrFixedCount - Either a CallFunctionOptions object or the fixedArgCount directly
 * @param fixedArgCountOrFirstArg - Number of fixed (non-variadic) arguments, or first arg if options were provided
 * @param args - The actual arguments to pass to the function
 * @returns The return value converted to a JavaScript type
 *
 * @example
 * ```typescript
 * import { NobjcLibrary, callVariadicFunction } from "objc-js";
 *
 * const Foundation = new NobjcLibrary(
 *   "/System/Library/Frameworks/Foundation.framework/Foundation"
 * );
 * const NSString = Foundation.NSString;
 *
 * // Simplest: void return, inferred args, fixedArgCount = 1
 * const format = NSString.stringWithUTF8String$("Hello, %@!");
 * const name = NSString.stringWithUTF8String$("World");
 * callVariadicFunction("NSLog", 1, format, name);
 *
 * // With explicit types
 * callVariadicFunction("NSLog", { returns: "v", args: ["@", "i"] }, 1, format, 42);
 * ```
 */
function callVariadicFunction(name: string, ...rest: any[]): any {
  let options: CallFunctionOptions | null = null;
  let restIdx = 0;

  if (rest.length > 0 && isCallOptions(rest[0])) {
    options = rest[0];
    restIdx = 1;
  }

  // fixedArgCount must be a number
  if (restIdx >= rest.length || typeof rest[restIdx] !== "number") {
    throw new Error("callVariadicFunction requires fixedArgCount as a number parameter");
  }
  const fixedArgCount = rest[restIdx];
  restIdx++;

  const args = rest.slice(restIdx);
  const { returnType, argTypes } = resolveTypes(options, args);

  // Unwrap NobjcObject proxies to native objects
  for (let i = 0; i < args.length; i++) {
    args[i] = unwrapArg(args[i]);
  }
  const result = CallFunction(name, returnType, argTypes, fixedArgCount, ...args);
  return wrapObjCObjectIfNeeded(result);
}

export {
  NobjcLibrary,
  NobjcObject,
  NobjcMethod,
  NobjcProtocol,
  NobjcClass,
  getPointer,
  fromPointer,
  callFunction,
  callVariadicFunction
};
