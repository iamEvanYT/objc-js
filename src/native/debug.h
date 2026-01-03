#ifndef DEBUG_H
#define DEBUG_H

#include <Foundation/Foundation.h>

// Debug logging control
// Set to 1 to enable verbose logging, 0 to disable
#ifndef NOBJC_DEBUG
  #define NOBJC_DEBUG 0
#endif

// Conditional logging macro - only logs when NOBJC_DEBUG is 1
#if NOBJC_DEBUG
  #define NOBJC_LOG(fmt, ...) NSLog(fmt, ##__VA_ARGS__)
#else
  #define NOBJC_LOG(fmt, ...) do { } while(0)
#endif

// Always-on error logging
#define NOBJC_ERROR(fmt, ...) NSLog(@"ERROR: " fmt, ##__VA_ARGS__)

// Always-on warning logging
#define NOBJC_WARN(fmt, ...) NSLog(@"WARNING: " fmt, ##__VA_ARGS__)

#endif // DEBUG_H
