import { NobjcLibrary, NobjcClass } from "./dist/index.js";

// Load required frameworks
const AuthServices = new NobjcLibrary(
  "/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices"
);
const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

const NSString = Foundation.NSString as any;
const NSArray = Foundation.NSArray as any;

// Load the ASAuthorizationController class first
const ASAuthorizationController = (AuthServices as any).ASAuthorizationController;
console.log("ASAuthorizationController loaded:", ASAuthorizationController);

// Define the subclass with the overridden method
export const WebauthnGetController = NobjcClass.define({
  name: "WebauthnGetController",
  superclass: "ASAuthorizationController",
  methods: {
    _requestContextWithRequests$error$: {
      types: "@@:@^@",
      implementation: (self: any, requests: any, outError: any) => {
        console.log("start (", requests, ")", outError);
        const context = NobjcClass.super(self, "_requestContextWithRequests$error$", requests, outError);
        console.log("done");

        return context;
      }
    }
  }
});

// Create a simple test
async function test() {
  try {
    console.log("Creating credential provider...");
    const ASAuthorizationPlatformPublicKeyCredentialProvider = (AuthServices as any)
      .ASAuthorizationPlatformPublicKeyCredentialProvider;

    const rpIdString = NSString.stringWithUTF8String$("example.com");
    const provider =
      ASAuthorizationPlatformPublicKeyCredentialProvider.alloc().initWithRelyingPartyIdentifier$(rpIdString);

    // Create a dummy challenge
    const challengeData = Foundation.NSData.alloc().initWithBytes$length$(Buffer.from("test"), 4);
    const request = provider.createCredentialAssertionRequestWithChallenge$(challengeData);

    // Create the controller using our custom subclass
    console.log("Creating controller with WebauthnGetController...");
    const requests = NSArray.arrayWithObject$(request);
    const controller = WebauthnGetController.alloc().initWithAuthorizationRequests$(requests);

    console.log(controller);
    console.log("Controller created successfully!");

    // Try to trigger the method (this will call our override)
    console.log("Calling performRequests (this should trigger our override)...");
    const result = (controller as any).performRequests();
    console.log("Result:", result);

    // Wait a bit for async operations
    await new Promise((resolve) => setTimeout(resolve, 1000));

    console.log("\n✅ Test passed! No crash occurred.");
  } catch (e) {
    console.error("❌ Test failed:", e);
    process.exit(1);
  }
}

test();
