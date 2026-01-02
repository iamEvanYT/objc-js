import { NobjcLibrary, NobjcObject, NobjcProtocol } from "./dist/index.js";

// Type declarations
interface _NSView extends NobjcObject {
  window(): _NSWindow;
}

interface _NSWindow extends NobjcObject {
  description(): _NSString;
}

interface _NSString extends NobjcObject {
  toString(): string;
}

interface _NSApplication extends NobjcObject {
  mainWindow(): _NSWindow | null;
}

interface _NSApplicationConstructor {
  sharedApplication(): _NSApplication;
}

// Load frameworks
const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");
const NSApplication = appKit["NSApplication"] as unknown as _NSApplicationConstructor;

// Test returning an object from a delegate callback
console.log("Testing object return value from delegate callback...");

let returnedValue: any = null;

const delegate = NobjcProtocol.implement("TestPresentationContextProvider", {
  "presentationAnchorForAuthorizationController:": (controller: NobjcObject) => {
    console.log("Callback invoked with controller:", controller);

    // Try to get the main window
    const app = NSApplication.sharedApplication();
    const mainWindow = app.mainWindow();

    console.log("Main window:", mainWindow);
    console.log("Returning window from callback...");

    returnedValue = mainWindow;
    return mainWindow;
  }
});

console.log("Delegate created:", delegate);

// Try to call the method directly
console.log("\nCalling method via performSelector...");
const result = (delegate as any).performSelector$withObject$(
  "presentationAnchorForAuthorizationController:",
  delegate // Pass delegate as a dummy controller
);

console.log("Result from performSelector:", result);
console.log("Returned value stored in callback:", returnedValue);

// Wait a bit for async operations
await new Promise((resolve) => setTimeout(resolve, 100));

console.log("\nFinal result:", result);
console.log("Result type:", typeof result);
console.log("Result is null?", result === null);
console.log("Result is undefined?", result === undefined);

if (result && typeof result === "object") {
  console.log("Result has description method?", typeof (result as any).description === "function");
  if (typeof (result as any).description === "function") {
    console.log("Result description:", (result as any).description());
  }
}
