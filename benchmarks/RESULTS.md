# Benchmark Results

> Generated: 2026-02-18 01:41:41 UTC  
> Git: `4f6e460`  
> Runtime: Bun 1.3.9  
> Platform: darwin arm64

## $msgSend Throughput

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| $msgSend: length (no args, int return) | 1.75M | 571 |
| $msgSend: UTF8String (no args, string return) | 1.60M | 626 |
| $msgSend: isEqualToString: (1 obj arg, bool return) | 1.24M | 806 |
| $msgSend: stringWithUTF8String: (1 string arg) | 708.42K | 1412 |
| $msgSend: numberWithInt: (1 int arg) | 683.27K | 1464 |
| $msgSend: intValue (no args, int return) | 1.70M | 590 |
| $msgSend: substringWithRange: (struct arg) | 567.83K | 1761 |
| $msgSend: rangeOfString: (obj arg, struct return) | 402.23K | 2486 |
| $msgSend: stringByAppendingString: (obj arg, obj return) | 289.34K | 3456 |
| $msgSend: respondsToSelector: via 'in' operator | 1.38M | 723 |

## Method Proxy Access

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| method access: same method repeated (cached) | 69.50M | 14 |
| method access + call: length() repeated | 1.71M | 586 |
| method access: toString() | 743.41K | 1345 |

## Property Access Guard

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| built-in prop: constructor | 60.24M | 17 |
| built-in prop: valueOf | 65.77M | 15 |
| built-in prop: hasOwnProperty | 64.76M | 15 |

## Struct Operations

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| struct arg: NSRange (2 fields) | 602.39K | 1660 |
| struct arg: CGPoint via NSValue | 532.20K | 1879 |
| struct arg: CGSize via NSValue | 562.86K | 1777 |
| struct arg: CGRect via NSValue (nested) | 530.74K | 1884 |
| struct return: NSRange via rangeValue | 1.28M | 783 |
| struct return: CGPoint via pointValue | 1.35M | 740 |
| struct return: CGRect via rectValue (nested) | 1.02M | 978 |
| struct roundtrip: CGRect pack + unpack | 244.78K | 4085 |

## Object Wrapping & Arguments

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| pass NobjcObject as argument | 1.23M | 812 |
| create + wrap NSString | 351.16K | 2848 |
| create + wrap NSNumber | 79.02K | 12655 |
| NSMutableArray: addObject + removeLastObject | 32.80K | 30489 |

## String Operations

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| NSString creation: short (5 chars) | 80.67K | 12396 |
| NSString creation: medium (50 chars) | 75.33K | 13274 |
| NSString creation: long (500 chars) | 56.62K | 17663 |
| NSString UTF8String extraction | 343.77K | 2909 |
| NSString toString (description) | 214.44K | 4663 |
| NSString length | 354.28K | 2823 |

## Multi-Argument Calls

| Benchmark | ops/sec | ns/op |
| :--- | ---: | ---: |
| 2 args: NSString compare:options: | 59.69K | 16753 |
| 4 args: NSWindow initWithContentRect:... | 577.11 | 1732777 |

## Summary

- **Total benchmarks:** 36
- **Fastest:** method access: same method repeated (cached) (69.50M ops/sec)
- **Slowest:** 4 args: NSWindow initWithContentRect:... (577.11 ops/sec)
