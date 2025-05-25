---
title: "Why Time Differences Can't Be Trusted"
date: 2025-05-23T18:35:12-03:00
tags: ["Windows", "Go", "Performance"]
draft: false
---

Time granularity on Windows is much lower than you'd expect, and that can cause surprising bugs when measuring elapsed time.

<!--more-->

---

I was investigating a seemingly random CI failure on Windows for a test in Elastic Agent. At random, the [ECS](https://www.elastic.co/docs/reference/ecs) field [`event.duration`](https://www.elastic.co/docs/reference/ecs/ecs-event#field-event-duration) would be missing from an ingested telemetry event.

To understand the root cause, let's investigate how Go retrieves system time across different operating systems.

## Understanding Clock Resolution

Clock resolution refers to the smallest measurable unit of time that a system clock or timer can reliably report. A high-resolution clock can measure very small time intervals, often in the microseconds or nanoseconds range. A low-resolution clock can only measure larger intervals, typically in milliseconds or seconds.

When you call `time.Now()` in Go, it returns the current wall-clock time, typically derived from the operating system's system clock. The accuracy and granularity of `time.Now()` depend heavily on the underlying system timer's resolution.

On Linux, the clock resolution for `time.Now()` is provided by the [vDSO](https://man7.org/linux/man-pages/man7/vdso.7.html) `clock_gettime` call, which is used by the runtime [time·now](https://github.com/golang/go/blob/8cb0941a85de6ddbd6f49f8e7dc2dd3caeeee61c/src/runtime/time_linux_amd64.s#L44C15-L44C34) function. The resolution is typically in the range of nanoseconds to microseconds, depending on the hardware and kernel implementation.

On Windows, Go [time·now](https://github.com/golang/go/blob/8cb0941a85de6ddbd6f49f8e7dc2dd3caeeee61c/src/runtime/time_windows_amd64.s#L17) just reads the system time out of a known memory location (0x7ffe0014 in the [KUSER_SHARED_DATA](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-kuser_shared_data) structure). The timer granularity is approximately 0.5 milliseconds, which is significantly coarser than on Linux.

I assume Go uses this approach on windows to avoid making a system call to retrieve the time, which would be expensive. For example, [CockroachDB calls `GetSystemTimePreciseAsFileTime`](https://github.com/cockroachdb/cockroach/pull/14597) to get a more precise time, but that is 2000x slower as of Go 1.8.

Here is a simple Go program to check the clock resolution on your system:

<details open>
<summary>check-clock-resolution.go</summary>

```go
package main

import (
	"fmt"
	"time"
)

func main() {
	start := time.Now()
	var delta time.Duration

	for {
		delta = time.Since(start)
		if delta > 0 {
			break
		}
	}

	fmt.Printf("Estimated time resolution: %v\n", delta)
}
```

</details>

| windows/amd64 | 521.7µs | 0.52ms     |
| ------------- | ------- | ---------- |
| linux/amd64   | 165ns   | 0.000165ms |
| darwin/arm64  | 667ns   | 0.000667ms |

## Always set a lower bound

If you're computing time differences for fast-executing code, the low timer resolution on Windows can result in a measured duration of zero. A common approach is to write something like `time.Since(start)` to calculate the elapsed time. This can introduce subtle, platform-dependent flakiness in your code.

To avoid this, always set a lower bound when taking time measurements:

```go
event.Took = max(time.Since(r.start), time.Nanosecond)
```

I fixed this issue in [elastic/beats#44442](https://github.com/elastic/beats/pull/44442).

## Conclusion

It's easy to assume that time.Since gives you a precise measurement, but that assumption breaks down once you factor in the operating system. Go does a good job of abstracting away platform differences, which can make issues like this easy to miss.

This isn't about Go, really. It's about not taking system behavior for granted. If your code relies on time measurements — for logs, metrics, or anything performance-critical — it pays to know what kind of precision you're actually getting.
