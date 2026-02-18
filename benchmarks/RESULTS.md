# Benchmark Results

> Generated: 2026-02-18 00:43:41 UTC  
> Git: `d7d7510`  
> Runtime: Bun 1.3.9  
> Platform: darwin arm64

## $msgSend Throughput

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| $msgSend: length (no args, int return) | 307.65K | 3250 |
| $msgSend: UTF8String (no args, string return) | 286.05K | 3496 |
| $msgSend: isEqualToString: (1 obj arg, bool return) | 281.42K | 3553 |
| $msgSend: stringWithUTF8String: (1 string arg) | 194.42K | 5143 |
| $msgSend: numberWithInt: (1 int arg) | 224.14K | 4462 |
| $msgSend: intValue (no args, int return) | 298.73K | 3347 |
| $msgSend: substringWithRange: (struct arg) | 162.88K | 6140 |
| $msgSend: rangeOfString: (obj arg, struct return) | 98.17K | 10186 |
| $msgSend: stringByAppendingString: (obj arg, obj return) | 48.07K | 20804 |
| $msgSend: respondsToSelector: via 'in' operator | 576.90K | 1733 |

## Method Proxy Access

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| method access: same method repeated (cached) | 613.91K | 1629 |
| method access + call: length() repeated | 336.64K | 2971 |
| method access: toString() | 384.85K | 2598 |

## Property Access Guard

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| built-in prop: constructor | 26.39M | 38 |
| built-in prop: valueOf | 29.03M | 34 |
| built-in prop: hasOwnProperty | 41.20M | 24 |

## Struct Operations

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| struct arg: NSRange (2 fields) | 318.35K | 3141 |
| struct arg: CGPoint via NSValue | 300.29K | 3330 |
| struct arg: CGSize via NSValue | 257.93K | 3877 |
| struct arg: CGRect via NSValue (nested) | 296.68K | 3371 |
| struct return: NSRange via rangeValue | 214.19K | 4669 |
| struct return: CGPoint via pointValue | 295.33K | 3386 |
| struct return: CGRect via rectValue (nested) | 287.09K | 3483 |
| struct roundtrip: CGRect pack + unpack | 53.85K | 18570 |

## Object Wrapping & Arguments

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| pass NobjcObject as argument | 326.46K | 3063 |
| create + wrap NSString | 215.33K | 4644 |
| create + wrap NSNumber | 231.71K | 4316 |
| NSMutableArray: addObject + removeLastObject | 56.24K | 17780 |

## String Operations

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| NSString creation: short (5 chars) | 184.43K | 5422 |
| NSString creation: medium (50 chars) | 116.59K | 8577 |
| NSString creation: long (500 chars) | 94.13K | 10623 |
| NSString UTF8String extraction | 332.59K | 3007 |
| NSString toString (description) | 395.17K | 2531 |
| NSString length | 370.14K | 2702 |

## Multi-Argument Calls

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| 2 args: NSString compare:options: | 121.75K | 8214 |
| 4 args: NSWindow initWithContentRect:... | 147.75 | 6768054 |

## Summary

- **Total benchmarks:** 36
- **Fastest:** built-in prop: hasOwnProperty (41.20M ops/sec)
- **Slowest:** 4 args: NSWindow initWithContentRect:... (147.75 ops/sec)
