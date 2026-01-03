# Subclassing / defineClass Design Document

## Overview

This document describes the design and implementation of `defineClass` - the ability to define new Objective-C classes from JavaScript, subclass existing classes, and override methods (including private selectors).

## Primary Use Case

Subclass `ASAuthorizationController` to override the private method:

```objc
- (id)_requestContextWithRequests:(NSArray<ASAuthorizationRequest*>*)requests
                            error:(NSError**)outError
```

Also create `NSObject` subclasses that implement:

- `ASAuthorizationControllerDelegate`
- `ASAuthorizationControllerPresentationContextProviding`

---

## 1. JavaScript API Surface

### 1.1 `NobjcClass.define()` - Main Entry Point

```typescript
interface MethodDefinition {
  // Type encoding string (Objective-C format)
  // e.g., "@@:@^@" for "id method:(NSArray*)requests error:(NSError**)outError"
  types: string;

  // The JavaScript implementation
  // Receives (self, ...args) - self is the instance, args are the method arguments
  // For methods with NSError** out-params, the arg is an object { set(error) }
  implementation: (self: NobjcObject, ...args: any[]) => any;
}

interface ClassDefinition {
  // Name of the new Objective-C class (must be unique in the runtime)
  name: string;

  // Superclass - either a class name string or a NobjcObject representing a Class
  superclass: string | NobjcObject;

  // Optional: protocols to conform to (for type checking / respondsToSelector)
  protocols?: string[];

  // Instance methods to implement/override
  // Key is the selector string (e.g., "_requestContextWithRequests:error:")
  methods?: Record<string, MethodDefinition>;

  // Optional: class methods (prefixed conceptually, but same format)
  classMethods?: Record<string, MethodDefinition>;

  // Optional: instance variables (for simple storage needs)
  ivars?: Record<string, string>; // name -> type encoding
}

// Returns the Class object (can be used to alloc/init instances)
function defineClass(definition: ClassDefinition): NobjcObject;
```

### 1.2 Calling Super

Within a method implementation, call super using a special helper:

```typescript
// Inside a method implementation:
implementation: (self, requests, errorOut) => {
  // Call super's implementation
  const result = NobjcClass.super(self, "_requestContextWithRequests:error:", requests, errorOut);

  // Modify the result
  if (result) {
    result.setClientDataHash$(myHashData);
  }

  return result;
};
```

### 1.3 NSError\*\* Out-Parameter Handling

For methods with `NSError**` out-parameters, we provide a setter object:

```typescript
implementation: (self, requests, errorOut) => {
  try {
    // Do something that might fail
    return someResult;
  } catch (e) {
    // Set the error using the out-param object
    errorOut.set(createNSError(e.message));
    return null;
  }
};
```

### 1.4 Type Encoding Reference

Common Objective-C type encodings:

```
@   = id (object)
#   = Class
:   = SEL (selector)
c   = char / BOOL (on older systems)
B   = BOOL (modern)
i   = int
I   = unsigned int
q   = long long / NSInteger (64-bit)
Q   = unsigned long long / NSUInteger (64-bit)
f   = float
d   = double
v   = void
*   = char* (C string)
^@  = id* (pointer to object, e.g., NSError**)
^v  = void* (generic pointer)
@?  = block
{name=...} = struct
```

For the `_requestContextWithRequests:error:` method:

- Return type: `@` (id)
- self: `@` (id)
- \_cmd: `:` (SEL)
- requests: `@` (NSArray\*)
- outError: `^@` (NSError\*\*)

Full encoding: `@@:@^@`

---

## 2. Native Implementation

### 2.1 New Native Function: `DefineClass`

```cpp
Napi::Value DefineClass(const Napi::CallbackInfo &info) {
  // 1. Parse arguments:
  //    - name: string
  //    - superclass: string or ObjcObject (Class)
  //    - protocols: string[] (optional)
  //    - methods: { selector: { types: string, implementation: Function } }

  // 2. Get or lookup superclass
  Class superClass = ...; // NSClassFromString or from ObjcObject

  // 3. Allocate class pair
  Class newClass = objc_allocateClassPair(superClass, className, 0);

  // 4. Add protocol conformance
  for (auto& protocolName : protocols) {
    Protocol* proto = objc_getProtocol(protocolName);
    if (proto) class_addProtocol(newClass, proto);
  }

  // 5. For each method:
  //    a. Parse type encoding
  //    b. Create ThreadSafeFunction for callback
  //    c. Add method with IMP pointing to our forwarding mechanism

  // 6. Store superclass info for super calls

  // 7. Register class
  objc_registerClassPair(newClass);

  // 8. Return the Class object
  return ObjcObject::NewInstance(env, newClass);
}
```

### 2.2 Updated Storage Structure

```cpp
struct SubclassMethodInfo {
  Napi::ThreadSafeFunction callback;
  Napi::FunctionReference jsCallback;
  std::string typeEncoding;
  std::string selectorName;
  Class superClass;  // For super calls
  bool isClassMethod;
};

struct SubclassImplementation {
  std::string className;
  Class objcClass;
  Class superClass;
  std::unordered_map<std::string, SubclassMethodInfo> methods;
  napi_env env;
  pthread_t js_thread;
  bool isElectron;
};

// Global storage: Class pointer -> implementation
extern std::unordered_map<void*, SubclassImplementation> g_subclasses;
```

### 2.3 Method Implementation Strategy

We use `class_addMethod` with direct IMP pointers using the forwarding mechanism:

```cpp
// For each method, we add it with our forwarding IMP
class_addMethod(newClass, selector, (IMP)_objc_msgForward, typeEncoding);

// Override forwardInvocation: to handle the call
class_addMethod(newClass, @selector(forwardInvocation:),
                (IMP)SubclassForwardInvocation, "v@:@");
class_addMethod(newClass, @selector(methodSignatureForSelector:),
                (IMP)SubclassMethodSignatureForSelector, "@@::");
```

### 2.4 Super Call Implementation

```cpp
Napi::Value CallSuper(const Napi::CallbackInfo &info) {
  // Args: self, selector, ...args

  // 1. Get the instance and its class
  id self = ...;
  Class instanceClass = object_getClass(self);

  // 2. Look up our subclass info to get the true superclass
  SubclassImplementation* impl = FindSubclassImpl(instanceClass);
  Class superClass = impl->superClass;

  // 3. Get the super method
  Method superMethod = class_getInstanceMethod(superClass, selector);
  IMP superIMP = method_getImplementation(superMethod);

  // 4. Build NSInvocation and call
  // ...
}
```

### 2.5 NSError\*\* Out-Parameter Handling

For pointer-to-pointer parameters (`^@`), we create a special JS object:

```cpp
// When extracting ^@ argument for JS callback:
if (typeCode == '^' && nextTypeCode == '@') {
  // Create a JS object with a 'set' method
  Napi::Object errorOutObj = Napi::Object::New(env);

  // Store the pointer location
  id* errorPtr = nullptr;
  [invocation getArgument:&errorPtr atIndex:index];

  // Create setter function that writes to the pointer
  errorOutObj.Set("set", Napi::Function::New(env, [errorPtr](const Napi::CallbackInfo& info) {
    if (errorPtr && info.Length() > 0) {
      id errorObj = unwrapArg(info[0]);
      *errorPtr = errorObj;
    }
  }));

  return errorOutObj;
}
```

---

## 3. Lifetime Management

### 3.1 Inflight Operations Map

For ASAuthorizationController operations, we need to prevent GC from collecting delegates while operations are in progress:

```typescript
// In JS layer
const inflightOperations = new Map<
  bigint,
  {
    controller: NobjcObject;
    delegate: NobjcObject;
    presentationProvider: NobjcObject;
    resolve: (result: any) => void;
    reject: (error: Error) => void;
  }
>();

function performAuthorization(controller, delegate, provider): Promise<AuthResult> {
  return new Promise((resolve, reject) => {
    const key = getPointer(controller).readBigUInt64LE(0);

    inflightOperations.set(key, {
      controller,
      delegate,
      presentationProvider: provider,
      resolve,
      reject
    });

    controller.setDelegate$(delegate);
    controller.setPresentationContextProvider$(provider);
    controller.performRequests();
  });
}

// In delegate callbacks, call cleanup:
function cleanup(controllerPtr: bigint) {
  inflightOperations.delete(controllerPtr);
}
```

### 3.2 Native Reference Counting

The native layer uses ARC (`-fobjc-arc`), which handles most memory management. However:

1. `ThreadSafeFunction` instances must be released when the class is disposed
2. `FunctionReference` instances keep JS callbacks alive
3. Global maps hold strong references until explicit cleanup

---

## 4. Threading Model

### 4.1 Main Thread Requirement

`ASAuthorizationController` must be used on the main thread. The bridge handles this:

```typescript
// JS wrapper ensures main thread execution
async function performRequestsOnMainThread(controller: NobjcObject) {
  // If we're not on main thread, dispatch there
  const NSOperationQueue = Foundation.NSOperationQueue;
  const mainQueue = NSOperationQueue.mainQueue();

  return new Promise((resolve) => {
    mainQueue.addOperationWithBlock$(() => {
      controller.performRequests();
      resolve();
    });
  });
}
```

### 4.2 Callback Thread Safety

The existing `method-forwarding.mm` already handles:

- JS thread detection via `pthread_equal`
- Cross-thread calls via `ThreadSafeFunction`
- Runloop pumping for synchronous return values
- Electron-specific handling

---

## 5. Complete Example: ASAuthorizationController Subclass

```typescript
import { NobjcLibrary, NobjcClass, NobjcProtocol, getPointer } from "nobjc";

const Foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const AuthServices = new NobjcLibrary(
  "/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices"
);
const AppKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");

const NSString = Foundation.NSString;
const NSData = Foundation.NSData;
const NSError = Foundation.NSError;
const NSArray = Foundation.NSArray;

// Inflight operations map (prevents GC)
const inflightOps = new Map();

// 1. Define custom controller subclass
const MyAuthController = NobjcClass.define({
  name: "MyAuthController",
  superclass: "ASAuthorizationController",
  methods: {
    // Override the private method to inject clientDataHash
    "_requestContextWithRequests:error:": {
      // Return: id, Args: self, _cmd, NSArray*, NSError**
      types: "@@:@^@",
      implementation: (self, requests, errorOut) => {
        // Call super to get the default context
        const context = NobjcClass.super(self, "_requestContextWithRequests:error:", requests, errorOut);

        if (context) {
          // Get the clientDataHash we stored on the controller
          const hash = self.clientDataHashOverride?.();
          if (hash) {
            // Set it on the credential request context
            context.setClientDataHash$(hash);
          }
        }

        return context;
      }
    },

    // Add a method to store our custom hash
    "setClientDataHashOverride:": {
      types: "v@:@", // void return, NSData* arg
      implementation: (self, hashData) => {
        // Store using associated object or ivar
        self._clientDataHash = hashData;
      }
    },

    clientDataHashOverride: {
      types: "@@:", // id return, no args (besides self/_cmd)
      implementation: (self) => {
        return self._clientDataHash || null;
      }
    }
  }
});

// 2. Create delegate implementing ASAuthorizationControllerDelegate
const MyDelegate = NobjcProtocol.implement("ASAuthorizationControllerDelegate", {
  "authorizationController:didCompleteWithAuthorization:": (controller, authorization) => {
    const key = getPointer(controller).readBigUInt64LE(0);
    const op = inflightOps.get(key);
    if (op) {
      const credential = authorization.credential();
      op.resolve({
        credentialID: credential.credentialID(),
        rawClientDataJSON: credential.rawClientDataJSON(),
        authenticatorData: credential.rawAuthenticatorData(),
        signature: credential.signature(),
        userID: credential.userID()
      });
      inflightOps.delete(key);
    }
  },

  "authorizationController:didCompleteWithError:": (controller, error) => {
    const key = getPointer(controller).readBigUInt64LE(0);
    const op = inflightOps.get(key);
    if (op) {
      op.reject(new Error(error.localizedDescription().toString()));
      inflightOps.delete(key);
    }
  }
});

// 3. Create presentation context provider
const MyPresentationProvider = NobjcProtocol.implement("ASAuthorizationControllerPresentationContextProviding", {
  "presentationAnchorForAuthorizationController:": (controller) => {
    // Return the key window
    const NSApp = AppKit.NSApplication.sharedApplication();
    return NSApp.keyWindow();
  }
});

// 4. Usage function
async function performPasskeyAssertion(rpId: string, challenge: Uint8Array, clientDataHash: Uint8Array): Promise<any> {
  // Create the request
  const provider =
    AuthServices.ASAuthorizationPlatformPublicKeyCredentialProvider.alloc().initWithRelyingPartyIdentifier$(
      NSString.stringWithUTF8String$(rpId)
    );

  const challengeData = NSData.dataWithBytes$length$(challenge, challenge.length);
  const request = provider.createCredentialAssertionRequestWithChallenge$(challengeData);

  // Create our custom controller
  const requests = NSArray.arrayWithObject$(request);
  const controller = MyAuthController.alloc().initWithAuthorizationRequests$(requests);

  // Set the custom clientDataHash
  const hashData = NSData.dataWithBytes$length$(clientDataHash, clientDataHash.length);
  controller.setClientDataHashOverride$(hashData);

  // Set up the operation tracking
  return new Promise((resolve, reject) => {
    const key = getPointer(controller).readBigUInt64LE(0);
    inflightOps.set(key, {
      controller,
      delegate: MyDelegate,
      provider: MyPresentationProvider,
      resolve,
      reject
    });

    controller.setDelegate$(MyDelegate);
    controller.setPresentationContextProvider$(MyPresentationProvider);
    controller.performRequests();
  });
}

export { performPasskeyAssertion };
```

---

## 6. Common Pitfalls

### 6.1 Type Encoding Errors

**Problem**: Wrong type encoding causes crashes or silent failures.
**Solution**: Always verify encodings match the actual method signature. Use `@encode()` in a test ObjC file if unsure.

### 6.2 Memory Management

**Problem**: Delegates get garbage collected before callbacks fire.
**Solution**: Use the inflight operations map pattern. Keep strong JS references until completion.

### 6.3 Threading Issues

**Problem**: `ASAuthorizationController` called from wrong thread.
**Solution**: Always dispatch to main thread before calling `performRequests()`.

### 6.4 Super Calls in Async Contexts

**Problem**: Super call happens after method returns.
**Solution**: Super calls must be synchronous within the method implementation.

### 6.5 Private API Stability

**Problem**: `_requestContextWithRequests:error:` may change between macOS versions.
**Solution**:

- Check method existence at runtime with `respondsToSelector:`
- Have fallback behavior if method doesn't exist
- Test on target macOS versions

---

## 7. Testing Strategy

### 7.1 Unit Test: Class Creation

```typescript
test("should create subclass of NSObject", () => {
  const MyClass = NobjcClass.define({
    name: "TestSubclass",
    superclass: "NSObject",
    methods: {
      testMethod: {
        types: "@@:",
        implementation: (self) => NSString.stringWithUTF8String$("Hello")
      }
    }
  });

  const instance = MyClass.alloc().init();
  const result = instance.testMethod();
  expect(result.toString()).toBe("Hello");
});
```

### 7.2 Unit Test: Super Calls

```typescript
test("should call super implementation", () => {
  const MyString = NobjcClass.define({
    name: "MyString",
    superclass: "NSMutableString",
    methods: {
      description: {
        types: "@@:",
        implementation: (self) => {
          const superDesc = NobjcClass.super(self, "description");
          return NSString.stringWithFormat$(NSString.stringWithUTF8String$("MyString: %@"), superDesc);
        }
      }
    }
  });

  const instance = MyString.alloc().initWithString$(NSString.stringWithUTF8String$("test"));
  expect(instance.description().toString()).toContain("MyString:");
});
```

### 7.3 Integration Test: Override Verification

```typescript
test("should invoke overridden method", () => {
  let overrideCalled = false;

  const MyClass = NobjcClass.define({
    name: "OverrideTest",
    superclass: "NSObject",
    methods: {
      init: {
        types: "@@:",
        implementation: (self) => {
          overrideCalled = true;
          return NobjcClass.super(self, "init");
        }
      }
    }
  });

  const instance = MyClass.alloc().init();
  expect(overrideCalled).toBe(true);
});
```
