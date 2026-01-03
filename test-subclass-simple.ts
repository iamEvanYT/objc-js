import { NobjcObject, NobjcClass } from "./src/ts/index";

const objc = new Proxy(
  {},
  {
    get(target, prop) {
      if (prop === "classes") {
        return new Proxy(
          {},
          {
            get(target, className: string) {
              const obj = (NobjcObject as any).constructor.prototype.constructor;
              const GetClassObject = require("./build/Release/nobjc_native.node").GetClassObject;
              return new NobjcObject(GetClassObject(className));
            }
          }
        );
      }
      return undefined;
    }
  }
);

console.log("Defining subclass...");
const MyClass = NobjcClass.define({
  name: "MySimpleTestClass",
  superclass: "NSObject",
  methods: {
    "testMethod:": {
      types: "v@:@",
      implementation: (self, arg) => {
        console.log("testMethod called with:", arg);
      }
    }
  }
});

console.log("Creating instance...");
const instance = (objc as any).classes.MySimpleTestClass.alloc().init();

console.log("Calling testMethod...");
instance.testMethod((objc as any).classes.NSString.stringWithUTF8String("Hello"));

console.log("Done!");
