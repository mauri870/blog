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

I ran it on [gorgonia/tensor](https://github.com/gorgonia/tensor), a Go library for N-dimensional array operations. Its `internal/execution` package has the arithmetic kernels: functions like `AddVSF32` (vector-scalar float32 add), `MulVSF64` (vector-scalar float64 multiply), `VecAddI32` (element-wise int32 add). Pure Go, no existing assembly. `loopvec -methods -split ./...` detected 176 vectorizable loops across the package.

Benchmarks on AMD Ryzen 9 9950X3D (AVX-512):

```
                          │    scalar     │              simd               │
                          │    sec/op     │   sec/op     vs base            │
AddVSF32/64-32               12.235n ± 0%   3.558n ± 1%  -70.92% (p=0.002 n=6)
AddVSF32/4096-32              762.5n ± 1%   146.9n ± 1%  -80.74% (p=0.002 n=6)
AddVSF32/1048576-32          201.21µ ± 1%   37.64µ ± 1%  -81.30% (p=0.002 n=6)
MulVSF32/64-32               14.115n ± 1%   3.736n ± 1%  -73.53% (p=0.002 n=6)
MulVSF32/4096-32              843.8n ± 2%   147.2n ± 1%  -82.56% (p=0.002 n=6)
MulVSF32/1048576-32          220.16µ ± 3%   37.43µ ± 0%  -83.00% (p=0.002 n=6)
AddVSF64/64-32               12.405n ± 1%   5.668n ± 5%  -54.31% (p=0.002 n=6)
AddVSF64/4096-32              757.7n ± 3%   286.8n ± 1%  -62.16% (p=0.002 n=6)
AddVSF64/1048576-32          204.33µ ± 1%   75.24µ ± 1%  -63.18% (p=0.002 n=6)
MulVSF64/64-32               12.445n ± 1%   5.907n ± 1%  -52.53% (p=0.002 n=6)
MulVSF64/4096-32              754.3n ± 1%   286.9n ± 1%  -61.97% (p=0.002 n=6)
MulVSF64/1048576-32          204.05µ ± 1%   75.39µ ± 2%  -63.05% (p=0.002 n=6)
VecAddI32/64-32              12.035n ± 1%   4.423n ± 1%  -63.24% (p=0.002 n=6)
VecAddI32/4096-32             761.0n ± 1%   194.9n ± 1%  -74.39% (p=0.002 n=6)
VecAddI32/1048576-32         204.74µ ± 1%   65.12µ ± 2%  -68.19% (p=0.002 n=6)
VecMulI32/64-32              14.440n ± 0%   4.464n ± 3%  -69.09% (p=0.002 n=6)
VecMulI32/4096-32             948.4n ± 0%   193.9n ± 1%  -79.55% (p=0.002 n=6)
VecMulI32/1048576-32         250.38µ ± 1%   64.80µ ± 1%  -74.12% (p=0.002 n=6)
geomean                        1.303µ        373.4n       -71.33%
```

71.33% geomean improvement. These functions are pure loop kernels with no existing vectorization, so the gains are real. For comparison, trivially simple loops like `a[i] += b[i]` are often already vectorized by the compiler and won't benefit.

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
