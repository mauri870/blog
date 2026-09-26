---
title: "Sub-millisecond Timer Precision in Go 1.28"
date: 2026-06-06T16:11:00-03:00
tags: ["Go", "Linux", "Performance"]
draft: false
---

Quiz: `time.Sleep(50 * time.Microsecond)` on Linux. How long does it actually sleep?

If you said 50µs, you're wrong. Let's see why and how to fix it.

<!--more-->

I recently submitted [CL 787700](https://go.dev/cl/787700), which switches Go's Linux netpoller to use the `epoll_pwait2` system call when available. The change is expected to land in Go 1.28.

## What is netpoll?

Go parks goroutines on I/O using `epoll` on Linux. The runtime blocks a thread in `epoll_wait` on [`runtime·netpoll`](https://github.com/golang/go/blob/d3be949ada01d7827f8edc87665fef5268634cb3/src/runtime/netpoll_epoll.go#L99) until file descriptors become ready, so the scheduler can wake them up.

Timers (`time.Sleep`, `time.After`, `time.Ticker`) are also routed through the same mechanism by converting deadlines into epoll timeouts.

## The problem

[`epoll_wait(2)`](https://man7.org/linux/man-pages/man2/epoll_wait.2.html) only accepts timeouts in milliseconds:

```c
int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
```

That `timeout` is an `int` in milliseconds.

So anything below 1ms gets rounded up in the runtime:

```go
var waitms int32
if delay < 0 {
    waitms = -1
} else if delay == 0 {
    waitms = 0
} else if delay < 1e6 {
    waitms = 1
} else if delay < 1e15 {
    waitms = int32(delay / 1e6)
} else {
    waitms = 1e9
}
```

A `time.Sleep(50 * time.Microsecond)` or any sub-millisecond timer becomes a **1ms sleep**. That is the lowest granularity for Go timers on Linux.

This is a neat benchmark using [loov/hrtime](https://github.com/loov/hrtime) that showcases this issue perfectly:

```go
package main

import (
    "fmt"
    "time"

    "github.com/loov/hrtime"
)

func main() {
    b := hrtime.NewBenchmark(100)
    for b.Next() {
        time.Sleep(50 * time.Microsecond)
    }
    fmt.Println(b.Histogram(10))
}
```

```bash
$ GOTOOLCHAIN=go1.26.3 go run .
  avg 1ms;  min 1ms;  p50 1ms;  max 1.01ms;
  p90 1ms;  p99 1.01ms;  p999 1.01ms;  p9999 1.01ms;
        1ms [ 57] ████████████████████████████████████████
     1.01ms [ 39] ███████████████████████████
     1.01ms [  1] ▌
     1.01ms [  0] 
     1.01ms [  1] ▌
     1.01ms [  1] ▌
     1.02ms [  1] ▌
     1.02ms [  0] 
     1.02ms [  0] 
     1.02ms [  0] 

```

This cluster is entirely `epoll_wait`'s rounding.

## Enter epoll_pwait2

Linux 5.11 added `epoll_pwait2(2)`:

```c
int epoll_pwait2(int epfd, struct epoll_event *events, int maxevents,
                 const struct __kernel_timespec *timeout,
                 const sigset_t *sigmask, size_t sigsetsize);
```

It takes a [`__kernel_timespec`](https://elixir.bootlin.com/linux/v7.0.11/source/include/uapi/linux/time_types.h#L7-L10). This new structure was added for the Y2038 problem. It's an exclusively 64-bit structure even on 32-bit platforms.

The feature is opt-in via `GODEBUG=epollpwait2=1`. The default retains `epoll_wait` behaviour because precise per-timer wakeups can measurably increase CPU usage for workloads with many distinct sub-millisecond timers. The coalescing section below covers why.

Detection runs once at startup. It checks the kernel version first, then probes the syscall with an invalid epfd. Seccomp filters can block `epoll_pwait2` independently of kernel version, returning `EPERM` instead of `ENOSYS`, so a version check alone is not sufficient:

```go
func netpollEpollPwait2Init() {
    if debug.epollpwait2 == 0 {
        return
    }
    if kv, ok := getKernelVersion(); ok && !kv.GE(5, 11) {
        return
    }
    _, errno := linux.EpollPwait2(-1, nil, 0, nil)
    const badf = 9 // EBADF
    epollpwait2Avail = errno == badf
}
```

An invalid `epfd` returns `EBADF` when the syscall is available; anything else (including `ENOSYS` or `EPERM` from seccomp) disables the feature.

## The coalescing problem

Nanosecond-precision timeouts exposed a subtlety. `epoll_wait`'s 1ms floor had a side effect: timers with nearby deadlines naturally collapsed into the same wakeup. Remove the floor, and every timer wakes independently.

Consider 50 goroutines sleeping 20µs, 40µs, …, 1000µs. With `epoll_wait` they all round up to 1ms and fire together in one wakeup. With `epoll_pwait2` each gets its own syscall: 50 wakeups.

To recover that batching, the runtime applies graduated bucketing to the timeout before the syscall. Timers whose coalesced deadlines land in the same bucket share a single wakeup. Bucket size scales with the delay at roughly 1% of the requested duration:

```
< 100µs:   1µs buckets
<   1ms:  10µs buckets
<  10ms: 100µs buckets
>= 10ms:   1ms buckets  (same as epoll_wait)
```

The delay is always rounded up, so no timer fires early.

Hot path:

```go
if epollpwait2Avail && delay != 0 {
    var ts *linux.KernelTimespec
    if delay > 0 {
        var timeout linux.KernelTimespec
        timeout.SetNsec(netpollCoalesceDelay(delay))
        ts = &timeout
    }
    // delay < 0: ts == nil, blocks indefinitely.
    n, errno = linux.EpollPwait2(epfd, events[:], int32(len(events)), ts)
} else {
    // epoll_pwait2 unavailable or delay == 0 (non-blocking): use epoll_wait.
}
```

## Results

With `GODEBUG=epollpwait2=1` the hrtime benchmark now shows:

```bash
$ GODEBUG=epollpwait2=1 go run .
  avg 53.8µs;  min 51.9µs;  p50 52.7µs;  max 65.6µs;
```

versus the default:

```bash
$ go run .
  avg 1ms;  min 1ms;  p50 1ms;  max 1.03ms;
```

Sub-millisecond timers finally work. A 50µs sleep now takes ~54µs, a few microseconds of overshoot well within normal OS scheduling jitter.

For the CPU cost, `BenchmarkSpreadSubMsTimers` (50 goroutines sleeping at staggered 20–1000µs intervals, each deadline in its own 10µs bucket) measures the worst case. 

```
                     |  epoll_wait   |      epollpwait2=1         |
                     |    sec/op     |    sec/op       vs base    |
SpreadSubMsTimers-32   1.064m ± 0%    1.019m ± 0%  -4.22% (p=0.000 n=10)

                     | cpu-ns/wakeup |  cpu-ns/wakeup   vs base  |
SpreadSubMsTimers-32   2.089µ ± 3%    7.182µ ± 2%  +243.86% (p=0.000 n=10)

                     |  wakeups/s   |   wakeups/s      vs base   |
SpreadSubMsTimers-32   46.99k ± 0%   49.06k ± 0%  +4.40% (p=0.000 n=10)
```

CPU per wakeup is 3.4 times higher because each goroutine gets its own syscall. Wall time improves by 4.22% and throughput by 4.40% because the last goroutine no longer waits for `epoll_wait`'s 1ms ceiling. Allocations and allocs/op are flat across both runs.

For timers that naturally cluster at the same deadline the cost is negligible, since they coalesce into a single wakeup just as `epoll_wait` would.

There is also a scheduler angle: an idle M blocks in netpoll until the next timer deadline, which `epoll_wait` ceils to 1ms, so timers fire late. With `epollpwait2` enabled, idle Ms wake at the exact deadline. This only matters when Ms are idle; under load, timer checks run at scheduling points regardless.

## Conclusion

Enable `GODEBUG=epollpwait2=1` if your workload uses sub-millisecond timers and you'd like to opt-in to get better latency.

Link to tracking issue: https://github.com/golang/go/issues/53824.

Special thanks to [Andrew Pogrebnoi](https://github.com/dAdAbird) for the initial iteration on the idea!
