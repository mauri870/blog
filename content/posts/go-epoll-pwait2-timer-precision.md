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

We can probe for it once at startup in [`runtime·osinit`](https://github.com/golang/go/blob/d00c67f297ef6f2cb2cd0e9aae59fa3936bb7eca/src/runtime/os_linux.go#L353), using a zero timeout. There could be seccomp filters in place that would also block it, so confirming it works before the runtime fully initializes and relies on it is a good idea.

```go
func netpollEpollPwait2Init() {
    var ts linux.KernelTimespec
    _, errno := linux.EpollPwait2(-1, nil, 0, &ts)
    epollpwait2Avail = errno != _ENOSYS
}
```

Pretty standard, if it's available the runtime uses it, otherwise it falls back to `epoll_wait`.

Hot path:

```go
if epollpwait2Avail {
    var timeout linux.KernelTimespec
    if delay > 0 {
        timeout.Sec = delay / 1e9
        timeout.Nsec = delay % 1e9
    }

    n, errno = linux.EpollPwait2(
        epfd,
        events,
        int32(len(events)),
        &timeout,
    )
} else {
    // fallback to epoll_wait
}
```

## Results

```bash
$ go install golang.org/dl/gotip@latest
$ gotip download 787700
$ gotip run .
  avg 53.5µs;  min 51.9µs;  p50 52.5µs;  max 62.2µs;
  p90 58.1µs;  p99 62.2µs;  p999 62.2µs;  p9999 62.2µs;
       52µs [  1] ▌
       52µs [ 79] ████████████████████████████████████████
       54µs [ 10] █████
       56µs [  0] 
       58µs [  2] █
       60µs [  2] █
       62µs [  6] ███
       64µs [  0] 
       66µs [  0] 
       68µs [  0] 

```

Sub-millisecond timers finally work. A 50µs sleep now takes 53µs, just a few microseconds of overshoot. That is well within normal OS scheduling jitter.

There is also a scheduler angle: an idle M blocks in netpoll until the next timer deadline, which epoll_wait ceils to 1ms, so timers fire late. This only matters when Ms are idle; under load, timer checks run at scheduling points regardless. This could shave latency off timer-driven wakeups, but I haven't profiled it.

## Conclusion

This change won't speed up most programs. But if your workload uses sub-millisecond timers or deadlines, expect noticeably reduced latency.

Link to tracking issue: https://github.com/golang/go/issues/53824.

Special thanks to [Andrew Pogrebnoi](https://github.com/dAdAbird) for the initial iteration on the idea!
