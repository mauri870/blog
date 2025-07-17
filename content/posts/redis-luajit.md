---
title: "Redis and LuaJIT"
date: 2025-07-14T18:00:00-03:00
tags: ["Redis", "LuaJIT", "Lua", "Performance"]
draft: false
---

Redis is a very popular in-memory store and has support for Lua scripts. But how about throwing LuaJIT into the mix?

<!--more-->

---

This is a quick post about my most recent endeavor, adding LuaJIT support to redis.

Porting the existing Lua `EVAL` command to use LuaJIT was surprisingly straightforward. You can check out the code [here](https://github.com/redis/redis/compare/unstable...mauri870:redis:luajit).

It's not production-ready, but the performance gains for compute-heavy lua code are obvious:

```bash
# luajit
$ redis-benchmark -n 1000 EVAL "local function fib(n)if n<2 then return n end return fib(n-1)+fib(n-2)end return fib(20)" 0
Summary:
  throughput summary: 4830.92 requests per second
  latency summary (msec):
          avg       min       p50       p95       p99       max
       10.035     1.280    10.175    10.903    11.183    11.399

# lua
redis-benchmark -n 1000 EVAL "local function fib(n)if n<2 then return n end return fib(n-1)+fib(n-2)end return fib(20)"
Summary:
  throughput summary: 1904.76 requests per second
  latency summary (msec):
          avg       min       p50       p95       p99       max
       25.841     3.184    25.711    27.631    28.047    28.511
```

> TL;DR: 2.5x increase in throughtput and 2.5x decrease in latency

While this doesn't necessarily translate to real-world production workloads, it clearly highlights the performance improvements LuaJIT can offer over standard Lua.
