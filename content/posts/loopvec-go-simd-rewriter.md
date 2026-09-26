---
title: "loopvec: automatic SIMD rewrites for Go loops"
date: 2026-09-25T12:00:00-03:00
tags: ["Go", "Performance", "SIMD"]
draft: false
---

Go 1.27 shipped an experimental `simd` package. I built a tool that automatically rewrites element-wise loops to use it.

<!--more-->

---

Go 1.27 introduced a `simd` package behind the `GOEXPERIMENT=simd` build flag. Instead of writing assembly, you use types like `simd.Float32s` and the compiler lowers them to AVX-512, AVX2, or NEON depending on the target. Writing the SIMD form by hand for every loop is tedious, so I built [loopvec](https://github.com/mauri870/loopvec) to do it automatically.

loopvec analyzes Go packages and rewrites element-wise loops. It recognizes patterns like `for i := range dst { dst[i] = a[i] + b[i] }`, `for i := range dst { dst[i] *= scalar }`, and similar shapes, and rewrites them to use the simd package. It supports `int8` through `uint64` and both float types.

The recommended workflow is `loopvec -split`, which writes the vectorized code to a new `_simd.go` file guarded by `//go:build goexperiment.simd` and adds the inverse tag to the original. Both files stay in the repository. The scalar version builds by default, and the SIMD version activates when you set the experiment flag.

## Benchmarks

I ran it on [gorgonia/tensor](https://github.com/gorgonia/tensor), a Go library for N-dimensional array operations. Its `internal/execution` package has the arithmetic kernels: functions like `AddVSF32` (vector-scalar float32 add), `MulVSF64` (vector-scalar float64 multiply), `VecAddI32` (element-wise int32 add). Pure Go, no existing assembly. `loopvec -split ./internal/execution/` detected 94 vectorizable loops across three files.

Benchmarks on AMD Ryzen 9 9950X3D (AVX-512):

```
                          │    scalar     │              simd               │
                          │    sec/op     │   sec/op     vs base            │
AddVSF32/64-32               12.315n ± 1%   3.608n ± 2%  -70.70% (p=0.002 n=6)
AddVSF32/4096-32              759.8n ± 2%   146.3n ± 1%  -80.75% (p=0.002 n=6)
AddVSF32/1048576-32          201.41µ ± 3%   37.42µ ± 2%  -81.42% (p=0.002 n=6)
MulVSF32/64-32               14.065n ± 2%   3.771n ± 7%  -73.19% (p=0.002 n=6)
MulVSF32/4096-32              843.9n ± 2%   149.2n ± 1%  -82.33% (p=0.002 n=6)
MulVSF32/1048576-32          219.59µ ± 3%   37.53µ ± 3%  -82.91% (p=0.002 n=6)
AddVSF64/64-32               12.475n ± 1%   5.716n ± 6%  -54.18% (p=0.002 n=6)
AddVSF64/4096-32              756.8n ± 3%   289.3n ± 2%  -61.77% (p=0.002 n=6)
AddVSF64/1048576-32          204.91µ ± 2%   75.05µ ± 2%  -63.37% (p=0.002 n=6)
MulVSF64/64-32               12.235n ± 1%   6.027n ± 2%  -50.74% (p=0.002 n=6)
MulVSF64/4096-32              756.1n ± 1%   286.1n ± 1%  -62.16% (p=0.002 n=6)
MulVSF64/1048576-32          204.16µ ± 1%   74.65µ ± 1%  -63.44% (p=0.002 n=6)
VecAddI32/64-32              12.040n ± 2%   4.350n ± 2%  -63.87% (p=0.002 n=6)
VecAddI32/4096-32             764.0n ± 3%   195.5n ± 1%  -74.41% (p=0.002 n=6)
VecAddI32/1048576-32         204.32µ ± 2%   63.44µ ± 3%  -68.95% (p=0.002 n=6)
VecMulI32/64-32              14.405n ± 1%   4.409n ± 3%  -69.40% (p=0.002 n=6)
VecMulI32/4096-32             948.9n ± 1%   196.1n ± 3%  -79.33% (p=0.002 n=6)
VecMulI32/1048576-32         249.27µ ± 1%   65.54µ ± 2%  -73.71% (p=0.002 n=6)
geomean                        1.302µ        373.9n       -71.28%
```

71% geomean improvement. These functions are pure loop kernels with no existing vectorization, so the gains are real. For comparison, trivially simple loops like `a[i] += b[i]` are often already vectorized by the compiler and won't benefit.

I also ran it on [gonum](https://github.com/gonum/gonum) and it found 103 vectorizable loops across 37 files, including BLAS and LAPACK kernels, optimization routines, and statistical functions.

## Caveats

I tested it on gonum and got regressions of 10-30%. Those routines have triangular inner loops: the slice length shrinks from `n` down to `1` as the outer index advances. Short inner loops don't benefit much from SIMD, so make sure to confirm if the code really got faster.

## Compiler bug

While testing and found a compiler bug ([golang/go#80657](https://github.com/golang/go/issues/80657)) where `GOEXPERIMENT=simd` crashed with an internal compiler error when a simd-tagged file contained a method on a named type. loopvec for now skips any loop inside a method to work around it. I have a preliminary fix at [go.dev/cl/839405](https://go.dev/cl/839405). With gotip pointing at that CL, loopvec can rewrite methods too.

## Conclusion

`GOEXPERIMENT=simd` is not in a stable Go release yet, so this is not something you would use in production today. But Go's SIMD support is moving quickly and the results on real code look good. The source is at [github.com/mauri870/loopvec](https://github.com/mauri870/loopvec).

```sh
go install github.com/mauri870/loopvec@latest
```
