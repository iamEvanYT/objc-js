declare module "#nobjc_native" {
  export class ObjcObject {
    $msgSend(selector: string, ...args: any[]): unknown;
    $respondsToSelector(selector: string): boolean;
    $prepareSend(selector: string): unknown;
    $msgSendPrepared(handle: unknown, ...args: any[]): unknown;
    $getPointer(): Buffer;
  }
  export function LoadLibrary(path: string): void;
  export function GetClassObject(name: string): ObjcObject;
  export function GetPointer(obj: ObjcObject): Buffer;
  export function FromPointer(pointer: Buffer | bigint): ObjcObject | null;
  export function CreateProtocolImplementation(
    protocolName: string,
    methodImplementations: Record<string, Function>
  ): ObjcObject;

  /** Method definition for DefineClass */
  export interface MethodDefinition {
    /** Objective-C type encoding string (e.g., "@@:@^@") */
    types: string;
    /** The JavaScript implementation function. Receives (self, ...args) */
    implementation: (self: ObjcObject, ...args: any[]) => any;
  }

  /** Class definition for DefineClass */
  export interface ClassDefinition {
    /** Name of the new Objective-C class (must be unique) */
    name: string;
    /** Superclass - either a class name string or a Class object */
    superclass: string | ObjcObject;
    /** Optional: protocols to conform to */
    protocols?: string[];
    /** Instance methods to implement/override */
    methods?: Record<string, MethodDefinition>;
    /** Optional: class methods */
    classMethods?: Record<string, MethodDefinition>;
  }

  /**
   * Define a new Objective-C class at runtime.
   * @param definition The class definition
   * @returns The new Class object (can be used to alloc/init instances)
   */
  export function DefineClass(definition: ClassDefinition): ObjcObject;

  /**
   * Call the superclass implementation of a method.
   * Use this inside a method implementation to invoke super.
   * @param self The instance (passed to your implementation)
   * @param selector The selector string (e.g., "init" or "_requestContextWithRequests:error:")
   * @param args Additional arguments to pass to super
   * @returns The result of the super call
   */
  export function CallSuper(self: ObjcObject, selector: string, ...args: any[]): any;

  /**
   * Call a C function by name using dlsym + libffi.
   * The framework containing the function must be loaded first (via LoadLibrary).
   * @param name The function name (e.g., "NSLog", "CGRectMake")
   * @param returnType ObjC type encoding for the return type (e.g., "v" for void, "@" for id)
   * @param argTypes Array of ObjC type encodings for each argument
   * @param fixedArgCount Number of fixed args (for variadic functions). Set equal to argTypes.length for non-variadic.
   * @param args The actual arguments to pass
   * @returns The return value converted to JS
   */
  export function CallFunction(
    name: string,
    returnType: string,
    argTypes: string[],
    fixedArgCount: number,
    ...args: any[]
  ): any;

  /**
   * Pump the macOS CFRunLoop in default mode.
   * Processes any pending run loop sources (AppKit events, dispatch_async to main queue,
   * timers, etc.) and returns immediately if none are pending.
   *
   * Required for async Objective-C callbacks (e.g., completion handlers) to be delivered
   * in a Node.js/Bun environment, where the CFRunLoop is not automatically pumped.
   *
   * @param timeout Optional timeout in seconds (default: 0, non-blocking)
   * @returns true if a source was processed, false otherwise
   */
  export function PumpRunLoop(timeout?: number): boolean;
}
