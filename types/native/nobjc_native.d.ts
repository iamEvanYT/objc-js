declare module "#nobjc_native" {
  export class ObjcObject {
    $msgSend(selector: string, ...args: any[]): unknown;
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
}
