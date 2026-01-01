declare module "#nobjc_native" {
  export class ObjcObject {
    $msgSend(selector: string, ...args: any[]): unknown;
    $getPointer(): Buffer;
  }
  export function LoadLibrary(path: string): void;
  export function GetClassObject(name: string): ObjcObject;
  export function GetPointer(obj: ObjcObject): Buffer;
  export function CreateProtocolImplementation(
    protocolName: string,
    methodImplementations: Record<string, Function>
  ): ObjcObject;
}
