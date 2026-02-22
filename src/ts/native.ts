import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
const require = createRequire(import.meta.url);
import * as _binding from "#nobjc_native";
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const binding: typeof _binding = require("node-gyp-build")(join(__dirname, ".."));

const {
  LoadLibrary,
  GetClassObject,
  ObjcObject,
  GetPointer,
  FromPointer,
  CreateProtocolImplementation,
  DefineClass,
  CallSuper,
  CallFunction,
  PumpRunLoop
} = binding;
export {
  LoadLibrary,
  GetClassObject,
  ObjcObject,
  GetPointer,
  FromPointer,
  CreateProtocolImplementation,
  DefineClass,
  CallSuper,
  CallFunction,
  PumpRunLoop
};
export type { _binding as NobjcNative };
