import { parentPort } from "node:worker_threads";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const binding = require("../../dist/native");

binding.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

const NSString = binding.GetClassObject("NSString");
binding.GetPointer(NSString);

parentPort?.postMessage("ready");
