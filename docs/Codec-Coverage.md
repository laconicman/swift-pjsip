# Codec coverage of the shipped binary

What the `PJSIP.xcframework` this package currently ships (0.4.0) does and does not carry, and why
it matters for downstream apps choosing codecs. (It is a release asset, not a file in this
repository — see ARCHITECTURE.md *Distribution*.)

## From the build parameters (the release notes for the pinned version)

configure flags:
`--disable-gsm-codec --disable-speex-codec --disable-speex-aec --enable-darwin-ssl
--enable-video --with-bcg729 --with-opus`, and `config_site.h` sets
`PJMEDIA_HAS_BCG729 1`, `PJMEDIA_HAS_OPUS_CODEC 1`, `PJMEDIA_HAS_INTEL_IPP_CODEC_G729 0`.

## Audio codec set

| Codec | Shipped | Note |
|---|---|---|
| **Opus** | ✓ | `opus/48000/2` (RFC 7587) via libopus `v1.6.1`, BSD-3-Clause + the Opus patent licence; folded into `libpjproject.a`, headers not shipped |
| G.711 µ-law / A-law (PCMU/PCMA) | ✓ | always built |
| G.722 | ✓ | built-in |
| G.722.1 (`g7221`) | ✓ | bundled third-party |
| iLBC | ✓ | bundled third-party |
| L16 | ✓ | built-in (pjsua registers it disabled by default) |
| G.729 (bcg729) | ✓ | `--with-bcg729`; GPLv3 + patents (see licensing) |
| GSM | ✗ | `--disable-gsm-codec` |
| Speex (codec + AEC) | ✗ | `--disable-speex-codec/-aec` (resampler may remain) |

Verified against the binary itself — `scripts/verify-xcframework.sh` asserts per slice that
`pjmedia_codec_opus_init` (the pjmedia wrapper, i.e. `PJMEDIA_HAS_OPUS_CODEC` was on) and
`opus_repacketizer_get_size` (the libopus object configure probes for) are defined symbols, and
that the GSM/Speex init symbols are absent.

## What Opus costs the consumer: clock rate

`opus/48000/2` is fixed by RFC 7587 — the wire format is always 48 kHz. pjsua's conference bridge
defaults to **16 kHz** (`PJSUA_DEFAULT_CLOCK_RATE`, also `snd_clock_rate`), so with the defaults an
Opus call resamples every frame in both directions. A consumer that wants Opus as its primary codec
sets `pjsua_media_config.clock_rate = 48000` (and `snd_clock_rate`, so the sound device runs at 48
kHz too). Codec selection and priority — `pjsua_codec_set_priority()` and friends — are the
wrapping engine's job; see laconicman/swift-pjsua#27. Note that Opus registers at
`PJMEDIA_CODEC_PRIO_NORMAL` like every other codec, in factory order after G.711/G.722/G.722.1
(`pjmedia-codec/audio_codecs.c`) — it is negotiated, not offered first; raising its offer position
is a `set_codec_priority` call the engine makes.

- Refs: the release notes for the pinned version; PJSIP media codecs
  <https://docs.pjsip.org/en/latest/>; Opus <https://opus-codec.org/>.
