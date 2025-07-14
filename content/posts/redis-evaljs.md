---
title: "Writing Redis Scripts with JavaScript"
date: 2025-07-14T18:20:00-03:00
tags: ["Redis", "JavaScript", "Performance"]
draft: false
---

Redis already supports Lua as a scripting language, allowing users to extend the functionality of Redis commands with custom scripts. However, JavaScript is a far more popular language overall, so how about writing Redis scripts in JS instead?

<!--more-->

---

This is another quick post about my recent work frenzy with Redis. I wanted to see if it is possible to use JavaScript as a scripting language in Redis, and if so, how that would compare to Lua both in functionality and performance.

I decided to use Rust to write a Redis extension, leveraging both [redismodule-rs](https://github.com/RedisLabsModules/redismodule-rs) and QuickJS to execute JavaScript code. The extension is available at [mauri870/redis-evaljs](https://github.com/mauri870/redis-evaljs).

Thanks to QuickJS supporting ES2023, you can use modern JavaScript features in your scripts:

```bash
$ redis-cli EVALJS "return 'Hello JS!'" 0
"Hello JS!"

$ redis-cli EVALJS "const fib = n => n <= 1 ? n : fib(n - 1) + fib(n - 2); return fib(10)" 0
(integer) 55

$ redis-cli EVALJS "return [5, 4, 3, 2, 1].toSorted()" 0
1) (integer) 1
2) (integer) 2
3) (integer) 3
4) (integer) 4
5) (integer) 5
```

I further augmented the extension with the ability to invoke Redis commands from within the JavaScript code:

```bash
$ redis-cli EVALJS "return redis.call('SET', 'a', 42)" 0
"OK"

$ redis-cli EVALJS "return redis.call('GET', 'a')" 0
"42"
```

Looking at the performance of simple code evaluation, it does not look too bad:

```bash
$ redis-benchmark EVALJS "return 1 + 2" 0
Summary:
  throughput summary: 44169.61 requests per second
  latency summary (msec):
          avg       min       p50       p95       p99       max
        0.919     0.240     0.871     1.423     1.671     2.367

$ redis-benchmark EVAL "return 1 + 2" 0
Summary:
  throughput summary: 58105.75 requests per second
  latency summary (msec):
          avg       min       p50       p95       p99       max
        0.654     0.240     0.591     1.127     1.343     2.023
```

It is not as fast as Lua, but it is the closest I could get to it. There is probably room for further optimization, but I think it is already good enough for most use cases.
