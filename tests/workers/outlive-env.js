// Creates Objective-C objects that call back into this worker's JS, then
// parks them where they outlive the worker (the main thread's dictionary).
import { parentPort, workerData } from "node:worker_threads";
import { NobjcLibrary, NobjcProtocol, NobjcClass } from "../../dist/index.js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"];
const key = (name) => NSString.stringWithUTF8String$(`${workerData.prefix}.${name}`);
const dict = foundation["NSThread"].mainThread().threadDictionary();

const operation = foundation["NSBlockOperation"].blockOperationWithBlock$(() => {});
dict.setObject$forKey$(operation, key("block"));

const cache = foundation["NSCache"].new();
cache.setDelegate$(NobjcProtocol.implement("NSCacheDelegate", { cache$willEvictObject$: () => {} }));
dict.setObject$forKey$(cache, key("protocol"));

const Subclass = NobjcClass.define({
  name: `${workerData.prefix}Subclass`,
  superclass: "NSObject",
  methods: { answer: { types: "i@:", implementation: () => 42 } }
});
dict.setObject$forKey$(Subclass.new(), key("subclass"));

parentPort.postMessage("ready");
