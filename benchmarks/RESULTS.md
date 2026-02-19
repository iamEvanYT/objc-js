# Benchmark Results

> Generated: 2026-02-19 13:27:11 UTC  
> Git: `fbe00fc`  
> Runtime: Bun 1.3.9  
> Platform: darwin arm64

## $msgSend Throughput

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| $msgSend: length (no args, int return) | 2.06M | 486 |
| $msgSend: UTF8String (no args, string return) | 1.84M | 545 |
| $msgSend: isEqualToString: (1 obj arg, bool return) | 1.48M | 675 |
| $msgSend: stringWithUTF8String: (1 string arg) | 721.07K | 1387 |
| $msgSend: numberWithInt: (1 int arg) | 690.30K | 1449 |
| $msgSend: intValue (no args, int return) | 1.81M | 552 |
| $msgSend: substringWithRange: (struct arg) | 752.65K | 1329 |
| $msgSend: rangeOfString: (obj arg, struct return) | 465.45K | 2148 |
| $msgSend: stringByAppendingString: (obj arg, obj return) | 276.09K | 3622 |
| $msgSend: respondsToSelector: via 'in' operator | 1.61M | 620 |

## Method Proxy Access

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| method access: same method repeated (cached) | 76.25M | 13 |
| method access + call: length() repeated | 1.97M | 509 |
| method access: toString() | 1.83M | 546 |

## Property Access Guard

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| built-in prop: constructor | 61.69M | 16 |
| built-in prop: valueOf | 64.30M | 16 |
| built-in prop: hasOwnProperty | 65.95M | 15 |

## Struct Operations

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| struct arg: NSRange (2 fields) | 728.04K | 1374 |
| struct arg: CGPoint via NSValue | 668.90K | 1495 |
| struct arg: CGSize via NSValue | 665.84K | 1502 |
| struct arg: CGRect via NSValue (nested) | 580.77K | 1722 |
| struct return: NSRange via rangeValue | 1.48M | 674 |
| struct return: CGPoint via pointValue | 1.59M | 630 |
| struct return: CGRect via rectValue (nested) | 650.42K | 1537 |
| struct roundtrip: CGRect pack + unpack | 24.78K | 40351 |

## Object Wrapping & Arguments

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| pass NobjcObject as argument | 511.05K | 1957 |
| create + wrap NSString | 91.19K | 10966 |
| create + wrap NSNumber | 91.59K | 10918 |
| NSMutableArray: addObject + removeLastObject | 38.98K | 25651 |

## String Operations

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| NSString creation: short (5 chars) | 88.57K | 11290 |
| NSString creation: medium (50 chars) | 87.93K | 11373 |
| NSString creation: long (500 chars) | 55.44K | 18037 |
| NSString UTF8String extraction | 542.48K | 1843 |
| NSString toString (description) | 499.71K | 2001 |
| NSString length | 580.33K | 1723 |

## Multi-Argument Calls

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| 2 args: NSString compare:options: | 73.02K | 13694 |
| 4 args: NSWindow initWithContentRect:... | 598.54 | 1670727 |

## Summary

- **Total benchmarks:** 36
- **Fastest:** method access: same method repeated (cached) (76.25M ops/sec)
- **Slowest:** 4 args: NSWindow initWithContentRect:... (598.54 ops/sec)
