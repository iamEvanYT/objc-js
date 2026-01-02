#ifndef METHOD_FORWARDING_H
#define METHOD_FORWARDING_H

#include "protocol-storage.h"
#include <napi.h>
#include <objc/runtime.h>

// Forward declarations for Objective-C types
#ifdef __OBJC__
@class NSMethodSignature;
@class NSInvocation;
#else
typedef struct NSMethodSignature NSMethodSignature;
typedef struct NSInvocation NSInvocation;
#endif

// MARK: - ThreadSafeFunction Callback

// Callback that runs on the JavaScript thread to invoke JS functions
void CallJSCallback(Napi::Env env, Napi::Function jsCallback,
                    InvocationData *data);

// MARK: - ObjC Runtime Method Implementations

// Override respondsToSelector to return YES for methods we implement
BOOL RespondsToSelector(id self, SEL _cmd, SEL selector);

// Method signature provider for message forwarding
NSMethodSignature *MethodSignatureForSelector(id self, SEL _cmd, SEL selector);

// Forward invocation handler for dynamic method dispatch
void ForwardInvocation(id self, SEL _cmd, NSInvocation *invocation);

// Deallocation implementation to clean up when instance is destroyed
void DeallocImplementation(id self, SEL _cmd);

#endif // METHOD_FORWARDING_H

