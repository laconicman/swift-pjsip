# Codec coverage of the shipped binary

What the `PJSIP.xcframework` this package currently ships does and does not carry, and why
it matters for downstream apps choosing codecs. (It is a release asset, not a file in this
repository — see ARCHITECTURE.md *Distribution*.)

## From the build parameters (the release notes for the pinned version)

configure flags:
`--disable-gsm-codec --disable-speex-codec --disable-speex-aec --enable-darwin-ssl
--enable-video --with-bcg729`, and `config_site.h` sets `PJMEDIA_HAS_BCG729 1`,
`PJMEDIA_HAS_INTEL_IPP_CODEC_G729 0`. There is **no** `--with-opus` and **no** libopus input.

## Expected audio codec set (verify — see below)

| Codec | Expected | Note |
|---|---|---|
| G.711 µ-law / A-law (PCMU/PCMA) | ✓ | always built |
| G.722 | ✓ | built-in |
| G.722.1 (`g7221`) | ✓ | bundled third-party |
| iLBC | ✓ | bundled third-party |
| L16 | ✓ | built-in |
| G.729 (bcg729) | ✓ | `--with-bcg729`; GPLv3 + patents (see licensing) |
| GSM | ✗ | `--disable-gsm-codec` |
| Speex (codec + AEC) | ✗ | `--disable-speex-codec/-aec` (resampler may remain) |
| **Opus** | ✗ | no `--with-opus` / no libopus |

## Opus is absent

Opus is the de-facto modern SIP/WebRTC audio codec; many providers and conferencing servers
negotiate it preferentially. It is **not** compiled into the shipped binary — confirmed by
symbol inspection — which limits interop and quality for a general-purpose softphone.

Confirmed via `nm` (no `opus_*` / `pjmedia_codec_opus*` symbols in the archive):

```
nm -gU .build/artifacts/*/PJSIP/PJSIP.xcframework/ios-arm64/libpjproject.a 2>/dev/null | grep -i -E 'opus|g7221|ilbc|bcg729'
```

(or extend `scripts/verify-xcframework.sh` with an Opus presence/absence assertion alongside
its existing GSM/Speex checks).

## Recommendation

For a full-featured softphone, add Opus to the build: provide libopus to `scripts/build.sh`,
pass `--with-opus`, and set `PJMEDIA_HAS_OPUS_CODEC 1` in `config_site.h` (this changes the
ABI, so it is a new binary/tag, not a downstream override — consistent with the existing
"do not override `config_site.h`" rule). Opus is royalty-free, so it adds no licensing
obligation beyond what PJSIP already carries.

> Tooling note: the sibling `pjsip-master 2` build tree in this workspace already carries
> `opus.sh` and a built `libopus.a`, so wiring Opus into `scripts/build.sh` is low-friction.

- Refs: the release notes for the pinned version; PJSIP media codecs
  <https://docs.pjsip.org/en/latest/>; Opus <https://opus-codec.org/>.
