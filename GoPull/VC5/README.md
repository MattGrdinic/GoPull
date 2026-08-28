# VC-5 decoder

Vendored from [gopro/gpr](https://github.com/gopro/gpr), Apache-2.0 or MIT.
Only the decoder is here — `vc5_decoder`, `vc5_common` and `common`. The
repository's `dng_sdk` (104k lines) is deliberately not vendored: a GPR is
already a DNG in every respect except that its single tile is VC-5 compressed,
so `GPRConverter` rewrites the container itself rather than pulling in Adobe's
SDK to do it.

Two files are renamed from the original, `vc5_common/syntax.c` and
`vc5_common/wavelet.c`, because Xcode derives object names from the basename
and `vc5_decoder` has files of the same name.

Nothing else is modified.
