# Vendored PawnIO modules

These are the author-signed PawnIO binaries from the official
[PawnIO.Modules](https://github.com/namazso/PawnIO.Modules) release
`0.2.11`:

- `AMDFamily17.bin` — sha256
  `dae74615761b78bdf064dfb3e136252ddcc6fc727d88f14738d0e5800d427a91`
- `COPYING` — GNU LGPL 2.1 text from the same release.

They are committed as signed release artifacts because `PawnIO.sys`
rejects modules that are not signed by the PawnIO author; building the
`.p` sources locally would produce an unsigned module.

Add more modules (for example `IntelMSR.bin`) from the same release as
needed.
