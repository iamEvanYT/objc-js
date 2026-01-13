import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
import * as _binding from "#nobjc_native";
import path from "node:path";
const binding: typeof _binding = require("node-gyp-build")(path.join(__dirname, ".."));

const {
  LoadLibrary,
  GetClassObject,
  ObjcObject,
  GetPointer,
  FromPointer,
  CreateProtocolImplementation,
  DefineClass,
  CallSuper
} = binding;
export {
  LoadLibrary,
  GetClassObject,
  ObjcObject,
  GetPointer,
  FromPointer,
  CreateProtocolImplementation,
  DefineClass,
  CallSuper
};
export type { _binding as NobjcNative };
