# Codec coverage of the shipped binary

What the `PJSIP.xcframework` this package currently ships (0.5.0) does and does not carry, and why
it matters for downstream apps choosing codecs. (It is a release asset, not a file in this
repository — see ARCHITECTURE.md *Distribution*.)

## From the build parameters (the release notes for the pinned version)

configure flags:
`--disable-gsm-codec --disable-speex-codec --disable-speex-aec --enable-darwin-ssl
--enable-video --with-bcg729 --with-opus`, and `config_site.h` sets
`PJMEDIA_HAS_BCG729 1`, `PJMEDIA_HAS_OPUS_CODEC 1`, `PJMEDIA_HAS_INTEL_IPP_CODEC_G729 0`.

## Audio codec set

This is the set **measured by enumeration** — `pjsua_enum_codecs()` on the shipped binary
(`audioCodecs()` in swift-pjsua) returns exactly these six, in this order:

```
iLBC/8000/1  PCMU/8000/1  PCMA/8000/1  G722/16000/1  opus/48000/2  G729/8000/1
```

| Codec | Shipped | Note |
|---|---|---|
| **Opus** | ✓ | `opus/48000/2` (RFC 7587) via libopus `v1.6.1`, BSD-3-Clause + the Opus patent licence; folded into `libpjproject.a`, headers not shipped |
| G.711 µ-law / A-law (PCMU/PCMA) | ✓ | always built |
| G.722 | ✓ | built-in |
| iLBC | ✓ | bundled third-party |
| G.729 (bcg729) | ✓ | `--with-bcg729`; GPLv3 + patents (see licensing) |
| G.722.1 (`g7221`) | ✗ | upstream default off (`pjmedia-codec/config.h` `PJMEDIA_HAS_G7221_CODEC 0`), not enabled — the bundled `third_party/g7221` tree being present is not the codec being registered |
| L16 | ✗ | disabled by the `PJ_CONFIG_IPHONE` preset (`config_site_sample.h` sets `PJMEDIA_HAS_L16_CODEC 0`); not re-enabled |
| GSM | ✗ | `--disable-gsm-codec` |
| Speex (codec + AEC) | ✗ | `--disable-speex-codec/-aec` (resampler may remain) |

G.722.1 and L16 are deliberately **not** enabled: G.722.1 is Polycom Siren7 and L16 is raw PCM,
and Opus already covers the wideband case both would serve. Each is one `config_site-ios.h` line
plus a MINOR bump per `docs/Versioning.md` if ever wanted.

Verified against the binary itself — `scripts/verify-xcframework.sh` asserts per slice that
`pjmedia_codec_opus_init` (the pjmedia wrapper, i.e. `PJMEDIA_HAS_OPUS_CODEC` was on) and
`opus_repacketizer_get_size` (the libopus object configure probes for) are defined symbols, and
that the GSM/Speex/G.722.1/L16 init symbols are absent.

## What Opus costs the consumer: clock rate

`opus/48000/2` is fixed by RFC 7587 — the wire format is always 48 kHz. pjsua's conference bridge
defaults to **16 kHz** (`PJSUA_DEFAULT_CLOCK_RATE`, also `snd_clock_rate`), so with the defaults an
Opus call resamples every frame in both directions. A consumer that wants Opus as its primary codec
sets `pjsua_media_config.clock_rate = 48000` (and `snd_clock_rate`, so the sound device runs at 48
kHz too). Codec selection and priority — `pjsua_codec_set_priority()` and friends — are the
wrapping engine's job; see laconicman/swift-pjsua#27. Note that Opus registers at
`PJMEDIA_CODEC_PRIO_NORMAL` like every other codec, in factory order after iLBC/G.711/G.722 and
before bcg729
(`pjmedia-codec/audio_codecs.c`) — it is negotiated, not offered first; raising its offer position
is a `set_codec_priority` call the engine makes.

- Refs: the release notes for the pinned version; PJSIP media codecs
  <https://docs.pjsip.org/en/latest/>; Opus <https://opus-codec.org/>.
