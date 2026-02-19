# Benchmark Results

> Generated: 2026-02-19 15:09:37 UTC  
> Git: `37094ec`  
> Runtime: Bun 1.3.9  
> Platform: darwin arm64

## $msgSend Throughput

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| $msgSend: length (no args, int return) | 17.47M | 57 |
| $msgSend: UTF8String (no args, string return) | 2.22M | 450 |
| $msgSend: isEqualToString: (1 obj arg, bool return) | 6.21M | 161 |
| $msgSend: stringWithUTF8String: (1 string arg) | 859.99K | 1163 |
| $msgSend: numberWithInt: (1 int arg) | 1.21M | 824 |
| $msgSend: intValue (no args, int return) | 13.57M | 74 |
| $msgSend: substringWithRange: (struct arg) | 799.09K | 1251 |
| $msgSend: rangeOfString: (obj arg, struct return) | 525.70K | 1902 |
| $msgSend: stringByAppendingString: (obj arg, obj return) | 462.96K | 2160 |
| $msgSend: respondsToSelector: via 'in' operator | 13.73M | 73 |

## Method Proxy Access

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| method access: same method repeated (cached) | 71.23M | 14 |
| method access + call: length() repeated | 16.44M | 61 |
| method access: toString() | 1.76M | 569 |

## Property Access Guard

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| built-in prop: constructor | 62.47M | 16 |
| built-in prop: valueOf | 68.76M | 15 |
| built-in prop: hasOwnProperty | 67.53M | 15 |

## Struct Operations

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| struct arg: NSRange (2 fields) | 776.62K | 1288 |
| struct arg: CGPoint via NSValue | 671.15K | 1490 |
| struct arg: CGSize via NSValue | 381.76K | 2619 |
| struct arg: CGRect via NSValue (nested) | 705.37K | 1418 |
| struct return: NSRange via rangeValue | 1.68M | 596 |
| struct return: CGPoint via pointValue | 1.74M | 575 |
| struct return: CGRect via rectValue (nested) | 1.32M | 757 |
| struct roundtrip: CGRect pack + unpack | 345.74K | 2892 |

## Object Wrapping & Arguments

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| pass NobjcObject as argument | 5.63M | 178 |
| create + wrap NSString | 797.58K | 1254 |
| create + wrap NSNumber | 1.01M | 987 |
| NSMutableArray: addObject + removeLastObject | 433.09K | 2309 |

## String Operations

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| NSString creation: short (5 chars) | 709.25K | 1410 |
| NSString creation: medium (50 chars) | 676.08K | 1479 |
| NSString creation: long (500 chars) | 570.38K | 1753 |
| NSString UTF8String extraction | 1.24M | 808 |
| NSString toString (description) | 296.37K | 3374 |
| NSString length | 370.02K | 2703 |

## Multi-Argument Calls

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| 2 args: NSString compare:options: | 42.75K | 23394 |
| 4 args: NSWindow initWithContentRect:... | 527.61 | 1895343 |

## Summary

- **Total benchmarks:** 36
- **Fastest:** method access: same method repeated (cached) (71.23M ops/sec)
- **Slowest:** 4 args: NSWindow initWithContentRect:... (527.61 ops/sec)
