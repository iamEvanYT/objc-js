/**
 * ASAuthorizationController Subclass Example
 *
 * This example demonstrates how to use nobjc's defineClass to:
 * 1. Subclass ASAuthorizationController and override a private method
 * 2. Create delegate/presentation provider implementations
 * 3. Perform passkey assertions with custom clientDataHash
 *
 * IMPORTANT: This uses the private method _requestContextWithRequests:error:
 * which is NOT part of Apple's public API. This approach is similar to what
 * Chromium does for WebAuthn support. NOT suitable for App Store apps.
 *
 * Tested on macOS 13.3+
 */

import { NobjcLibrary, NobjcObject, NobjcClass, NobjcProtocol, getPointer } from "../dist/index.js";

// Load required frameworks
const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const AuthServices = new NobjcLibrary(
  "/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices"
);
const AppKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");

// Get commonly used classes
const NSString = Foundation.NSString as any;
const NSData = Foundation.NSData as any;
const NSError = Foundation.NSError as any;
const NSArray = Foundation.NSArray as any;
const NSMutableArray = Foundation.NSMutableArray as any;
const NSDictionary = Foundation.NSDictionary as any;
const NSMutableDictionary = Foundation.NSMutableDictionary as any;

// ============================================================================
// INFLIGHT OPERATIONS MAP
// This prevents garbage collection from deallocating delegates mid-flight
// ============================================================================

interface InflightOperation {
  controller: NobjcObject;
  delegate: NobjcObject;
  presentationProvider: NobjcObject;
  clientDataHash?: Uint8Array;
  resolve: (result: PasskeyAssertionResult) => void;
  reject: (error: Error) => void;
}

const inflightOperations = new Map<bigint, InflightOperation>();

function cleanup(controllerPtr: bigint): void {
  inflightOperations.delete(controllerPtr);
}

// ============================================================================
// TYPE DEFINITIONS
// ============================================================================

interface PasskeyAssertionResult {
  credentialID: Uint8Array;
  authenticatorData: Uint8Array;
  signature: Uint8Array;
  userHandle?: Uint8Array;
  rawClientDataJSON?: Uint8Array;
}

// ============================================================================
// 1. CUSTOM CONTROLLER SUBCLASS
// Overrides _requestContextWithRequests:error: to inject clientDataHash
// ============================================================================

// Storage for the clientDataHash per controller instance
// We use WeakMap-like approach with the controller pointer as key
const controllerDataHashMap = new Map<bigint, NobjcObject>();

/**
 * Custom ASAuthorizationController subclass.
 *
 * This class overrides the private method _requestContextWithRequests:error:
 * to set a custom clientDataHash on the credential request context.
 *
 * The type encoding "@@:@^@" means:
 * - @ = return type (id)
 * - @ = self (id)
 * - : = _cmd (SEL)
 * - @ = requests (NSArray*)
 * - ^@ = outError (NSError**)
 */
const MyAuthController = NobjcClass.define({
  name: "MyAuthController",
  superclass: "ASAuthorizationController",
  methods: {
    // Override the private method to inject clientDataHash
    "_requestContextWithRequests:error:": {
      types: "@@:@^@",
      implementation: (self, requests, errorOut) => {
        console.log("[MyAuthController] ========================================");
        console.log("[MyAuthController] _requestContextWithRequests:error: called");
        console.log("[MyAuthController] self:", self);
        console.log("[MyAuthController] requests:", requests);
        console.log("[MyAuthController] errorOut:", errorOut);

        // Call super to get the default context
        console.log("[MyAuthController] Calling super...");
        const context = NobjcClass.super(self, "_requestContextWithRequests:error:", requests, errorOut);
        console.log("[MyAuthController] Super returned context:", context);

        if (context) {
          // Get the clientDataHash we stored for this controller
          const controllerPtr = getPointer(self).readBigUInt64LE(0);
          console.log("[MyAuthController] Controller pointer:", controllerPtr);

          const hashData = controllerDataHashMap.get(controllerPtr);
          console.log("[MyAuthController] Hash data:", hashData);

          if (hashData) {
            console.log("[MyAuthController] Setting custom clientDataHash on context");
            // The context should have a method to set the clientDataHash
            // This is based on Chromium's approach
            try {
              (context as any).setClientDataHash$(hashData);
              console.log("[MyAuthController] clientDataHash set successfully");
            } catch (e) {
              console.warn("[MyAuthController] Failed to set clientDataHash:", e);
            }
          }
        }

        console.log("[MyAuthController] Returning context:", context);
        console.log("[MyAuthController] ========================================");
        return context;
      }
    }
  }
});

console.log("[DefineClass] MyAuthController class defined:", MyAuthController);

/**
 * Helper to set the clientDataHash for a controller before calling performRequests.
 */
function setClientDataHashForController(controller: NobjcObject, hashData: NobjcObject): void {
  const ptr = getPointer(controller).readBigUInt64LE(0);
  controllerDataHashMap.set(ptr, hashData);
}

// ============================================================================
// 2. DELEGATE IMPLEMENTATION
// Implements ASAuthorizationControllerDelegate protocol
// ============================================================================

/**
 * Create a delegate that handles authorization completion.
 * The delegate methods receive wrapped NobjcObjects.
 */
function createDelegate(): NobjcObject {
  return NobjcProtocol.implement("ASAuthorizationControllerDelegate", {
    // Called when authorization completes successfully
    "authorizationController:didCompleteWithAuthorization:": (controller: NobjcObject, authorization: NobjcObject) => {
      console.log("[Delegate] didCompleteWithAuthorization");

      const controllerPtr = getPointer(controller).readBigUInt64LE(0);
      const op = inflightOperations.get(controllerPtr);

      if (!op) {
        console.error("[Delegate] No inflight operation found for controller");
        return;
      }

      try {
        const credential = (authorization as any).credential();

        // Extract credential data
        const credentialID = nsDataToUint8Array((credential as any).credentialID());
        const authenticatorData = nsDataToUint8Array((credential as any).rawAuthenticatorData());
        const signature = nsDataToUint8Array((credential as any).signature());

        let userHandle: Uint8Array | undefined;
        try {
          const userIDData = (credential as any).userID();
          if (userIDData) {
            userHandle = nsDataToUint8Array(userIDData);
          }
        } catch {
          // userID may not be available
        }

        const result: PasskeyAssertionResult = {
          credentialID,
          authenticatorData,
          signature,
          userHandle
        };

        console.log("[Delegate] Resolving with credential");
        op.resolve(result);
      } catch (e) {
        console.error("[Delegate] Error extracting credential:", e);
        op.reject(e as Error);
      } finally {
        cleanup(controllerPtr);
      }
    },

    // Called when authorization fails
    "authorizationController:didCompleteWithError:": (controller: NobjcObject, error: NobjcObject) => {
      console.log("[Delegate] didCompleteWithError");

      const controllerPtr = getPointer(controller).readBigUInt64LE(0);
      const op = inflightOperations.get(controllerPtr);

      if (!op) {
        console.error("[Delegate] No inflight operation found for controller");
        return;
      }

      const errorDesc = (error as any).localizedDescription().toString();
      const errorCode = (error as any).code() as number;

      console.error(`[Delegate] Authorization error (${errorCode}): ${errorDesc}`);
      op.reject(new Error(`AuthorizationError (${errorCode}): ${errorDesc}`));
      cleanup(controllerPtr);
    }
  });
}

// ============================================================================
// 3. PRESENTATION CONTEXT PROVIDER
// Implements ASAuthorizationControllerPresentationContextProviding
// ============================================================================

/**
 * Create a presentation context provider that returns the key window.
 */
function createPresentationProvider(): NobjcObject {
  return NobjcProtocol.implement("ASAuthorizationControllerPresentationContextProviding", {
    "presentationAnchorForAuthorizationController:": (controller: NobjcObject): NobjcObject => {
      console.log("[PresentationProvider] presentationAnchorForAuthorizationController:");

      // Return the key window
      const NSApp = (AppKit as any).NSApplication.sharedApplication();
      const keyWindow = NSApp.keyWindow();

      if (!keyWindow) {
        console.warn("[PresentationProvider] No key window found, using main window");
        const mainWindow = NSApp.mainWindow();
        if (mainWindow) {
          return mainWindow;
        }
        // Last resort: get first window
        const windows = NSApp.windows();
        if ((windows as any).count() > 0) {
          return (windows as any).objectAtIndex$(0);
        }
      }

      return keyWindow;
    }
  });
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

/**
 * Convert NSData to Uint8Array
 */
function nsDataToUint8Array(nsData: NobjcObject): Uint8Array {
  const length = (nsData as any).length() as number;
  const bytes = (nsData as any).bytes();

  // bytes() returns a void* pointer - we need to read it
  // For now, use a workaround via base64 encoding
  const base64 = (nsData as any).base64EncodedStringWithOptions$(0).toString();
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

/**
 * Convert Uint8Array to NSData
 */
function uint8ArrayToNSData(arr: Uint8Array): NobjcObject {
  // Convert to base64 and create NSData from base64 string
  const base64 = btoa(String.fromCharCode(...arr));
  const nsString = NSString.stringWithUTF8String$(base64);
  return NSData.alloc().initWithBase64EncodedString$options$(nsString, 0);
}

/**
 * Create a SHA-256 hash of the input data.
 * Uses CommonCrypto via the Objective-C runtime.
 */
function sha256(data: Uint8Array): Uint8Array {
  // For a real implementation, you'd want to use CommonCrypto
  // This is a placeholder that would need proper implementation
  // using CC_SHA256 via nobjc

  // For now, assume the caller provides the pre-computed hash
  return data;
}

// ============================================================================
// MAIN API
// ============================================================================

/**
 * Perform a passkey assertion with a custom clientDataHash.
 *
 * This is the main entry point for WebAuthn-style authentication
 * where you need to control the clientDataHash for proper signature validation.
 *
 * @param rpId - The relying party identifier (e.g., "example.com")
 * @param challenge - The challenge from the server (raw bytes)
 * @param clientDataHash - The SHA-256 hash of the clientDataJSON (32 bytes)
 * @param allowedCredentials - Optional list of allowed credential IDs
 *
 * @returns Promise resolving to the assertion result
 *
 * @example
 * ```typescript
 * // Compute clientDataHash from your clientDataJSON
 * const clientDataJSON = JSON.stringify({
 *   type: "webauthn.get",
 *   challenge: base64url(challenge),
 *   origin: "https://example.com",
 *   crossOrigin: false
 * });
 * const clientDataHash = sha256(new TextEncoder().encode(clientDataJSON));
 *
 * const result = await performPasskeyAssertion(
 *   "example.com",
 *   challenge,
 *   clientDataHash
 * );
 * ```
 */
export async function performPasskeyAssertion(
  rpId: string,
  challenge: Uint8Array,
  clientDataHash: Uint8Array,
  allowedCredentials?: Uint8Array[]
): Promise<PasskeyAssertionResult> {
  return new Promise((resolve, reject) => {
    try {
      console.log("[performPasskeyAssertion] ========================================");
      console.log("[performPasskeyAssertion] Starting with rpId:", rpId);

      // Create the credential provider
      const ASAuthorizationPlatformPublicKeyCredentialProvider = (AuthServices as any)
        .ASAuthorizationPlatformPublicKeyCredentialProvider;

      console.log("[performPasskeyAssertion] Creating provider...");
      const rpIdString = NSString.stringWithUTF8String$(rpId);
      const provider =
        ASAuthorizationPlatformPublicKeyCredentialProvider.alloc().initWithRelyingPartyIdentifier$(rpIdString);
      console.log("[performPasskeyAssertion] Provider created:", provider);

      // Create the assertion request
      console.log("[performPasskeyAssertion] Creating request...");
      const challengeData = uint8ArrayToNSData(challenge);
      const request = provider.createCredentialAssertionRequestWithChallenge$(challengeData);
      console.log("[performPasskeyAssertion] Request created:", request);

      // Set allowed credentials if provided
      if (allowedCredentials && allowedCredentials.length > 0) {
        console.log("[performPasskeyAssertion] Setting allowed credentials...");
        const descriptors = NSMutableArray.array();
        for (const credId of allowedCredentials) {
          const credIdData = uint8ArrayToNSData(credId);
          const descriptor = (
            AuthServices as any
          ).ASAuthorizationPlatformPublicKeyCredentialDescriptor.alloc().initWithCredentialID$(credIdData);
          descriptors.addObject$(descriptor);
        }
        (request as any).setAllowedCredentials$(descriptors);
        console.log("[performPasskeyAssertion] Allowed credentials set");
      }

      // Create the controller using our custom subclass
      console.log("[performPasskeyAssertion] Creating controller with MyAuthController...");
      const requests = NSArray.arrayWithObject$(request);
      console.log("[performPasskeyAssertion] Requests array:", requests);

      const controller = MyAuthController.alloc().initWithAuthorizationRequests$(requests);
      console.log("[performPasskeyAssertion] Controller created:", controller);
      console.log("[performPasskeyAssertion] Controller class:", (controller as any).class());

      // Set the custom clientDataHash
      console.log("[performPasskeyAssertion] Setting clientDataHash...");
      const hashData = uint8ArrayToNSData(clientDataHash);
      setClientDataHashForController(controller, hashData);
      console.log("[performPasskeyAssertion] clientDataHash set");

      // Create delegate and presentation provider
      console.log("[performPasskeyAssertion] Creating delegate...");
      const delegate = createDelegate();
      console.log("[performPasskeyAssertion] Delegate created:", delegate);

      console.log("[performPasskeyAssertion] Creating presentation provider...");
      const presentationProvider = createPresentationProvider();
      console.log("[performPasskeyAssertion] Presentation provider created:", presentationProvider);

      // Register inflight operation BEFORE setting delegate
      // to ensure we don't miss any callbacks
      const controllerPtr = getPointer(controller).readBigUInt64LE(0);
      console.log("[performPasskeyAssertion] Controller pointer:", controllerPtr);

      inflightOperations.set(controllerPtr, {
        controller,
        delegate,
        presentationProvider,
        clientDataHash,
        resolve,
        reject
      });
      console.log("[performPasskeyAssertion] Inflight operation registered");

      // Set delegate and presentation provider
      console.log("[performPasskeyAssertion] Setting delegate on controller...");
      (controller as any).setDelegate$(delegate);
      console.log("[performPasskeyAssertion] Delegate set");

      console.log("[performPasskeyAssertion] Setting presentation provider on controller...");
      (controller as any).setPresentationContextProvider$(presentationProvider);
      console.log("[performPasskeyAssertion] Presentation provider set");

      console.log("[performPasskeyAssertion] Calling performRequests...");
      console.log("[performPasskeyAssertion] ========================================");

      // Perform the authorization request
      (controller as any).performRequests();

      console.log("[performPasskeyAssertion] performRequests called (may be async)");
    } catch (e) {
      console.error("[performPasskeyAssertion] ERROR:", e);
      reject(e);
    }
  });
}

/**
 * Perform a passkey registration (creation) with a custom clientDataHash.
 *
 * Similar to performPasskeyAssertion but for credential creation.
 */
export async function performPasskeyRegistration(
  rpId: string,
  rpName: string,
  userId: Uint8Array,
  userName: string,
  userDisplayName: string,
  challenge: Uint8Array,
  clientDataHash: Uint8Array
): Promise<any> {
  return new Promise((resolve, reject) => {
    try {
      const ASAuthorizationPlatformPublicKeyCredentialProvider = (AuthServices as any)
        .ASAuthorizationPlatformPublicKeyCredentialProvider;

      const rpIdString = NSString.stringWithUTF8String$(rpId);
      const provider =
        ASAuthorizationPlatformPublicKeyCredentialProvider.alloc().initWithRelyingPartyIdentifier$(rpIdString);

      // Create registration request
      const challengeData = uint8ArrayToNSData(challenge);
      const userIdData = uint8ArrayToNSData(userId);
      const userNameString = NSString.stringWithUTF8String$(userName);

      const request = provider.createCredentialRegistrationRequestWithChallenge$name$userID$(
        challengeData,
        userNameString,
        userIdData
      );

      // Create controller
      const requests = NSArray.arrayWithObject$(request);
      const controller = MyAuthController.alloc().initWithAuthorizationRequests$(requests);

      // Set custom clientDataHash
      const hashData = uint8ArrayToNSData(clientDataHash);
      setClientDataHashForController(controller, hashData);

      // Create delegate and provider
      const delegate = createDelegate();
      const presentationProvider = createPresentationProvider();

      const controllerPtr = getPointer(controller).readBigUInt64LE(0);
      inflightOperations.set(controllerPtr, {
        controller,
        delegate,
        presentationProvider,
        clientDataHash,
        resolve: resolve as any,
        reject
      });

      (controller as any).setDelegate$(delegate);
      (controller as any).setPresentationContextProvider$(presentationProvider);
      (controller as any).performRequests();
    } catch (e) {
      reject(e);
    }
  });
}

// ============================================================================
// USAGE EXAMPLE
// ============================================================================

/*
// Example usage in an Electron or Node.js application:

import { performPasskeyAssertion } from "./examples/asauthorization-subclass.js";

async function authenticate() {
  // Server provides challenge
  const challenge = new Uint8Array([/* challenge bytes * /]);

  // Build clientDataJSON as per WebAuthn spec
  const clientDataJSON = JSON.stringify({
    type: "webauthn.get",
    challenge: base64url(challenge),
    origin: "https://myapp.example.com",
    crossOrigin: false
  });

  // Compute SHA-256 hash of clientDataJSON
  const clientDataHash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(clientDataJSON)
  );

  try {
    const result = await performPasskeyAssertion(
      "example.com",                    // rpId
      challenge,                         // challenge
      new Uint8Array(clientDataHash),    // clientDataHash
      [/* allowed credential IDs * /]    // optional
    );

    console.log("Authentication successful!");
    console.log("Credential ID:", result.credentialID);
    console.log("Authenticator Data:", result.authenticatorData);
    console.log("Signature:", result.signature);

    // Send result to server for verification
    await sendToServer(result);
  } catch (error) {
    console.error("Authentication failed:", error);
  }
}
*/
