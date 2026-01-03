#ifndef SUBCLASS_IMPL_H
#define SUBCLASS_IMPL_H

#include <napi.h>

// Define a new Objective-C class at runtime from JavaScript
// Arguments: { name: string, superclass: string|Class, protocols?: string[], methods?: {...} }
// Returns: The new Class object
Napi::Value DefineClass(const Napi::CallbackInfo &info);

// Call the superclass implementation of a method
// Arguments: self, selectorName, ...args
// Returns: The result of the super call
Napi::Value CallSuper(const Napi::CallbackInfo &info);

// Callback handler for subclass methods (called from JS thread)
void CallSubclassJSCallback(Napi::Env env, Napi::Function jsCallback,
                            struct InvocationData *data);

#endif // SUBCLASS_IMPL_H
