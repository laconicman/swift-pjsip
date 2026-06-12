# PJSIP.xcframework — build release notes

Provenance of the **currently committed** binary. This build predates the
automated notes generator (`scripts/build.sh notes`); future builds will replace
this file with a fully machine-generated report.

## Sources

| Component | Resolved ref | Origin |
|-----------|--------------|--------|
| PJSIP | `2.16` + iPhone 17 device patch | https://github.com/pjsip/pjproject |
| bcg729 | master (build-time HEAD) | https://github.com/BelledonneCommunications/bcg729 |

## Build parameters

- Slices: `ios-arm64` (device), `ios-arm64-simulator`
- Minimum iOS: `15.0`
- configure flags: `--disable-gsm-codec --disable-speex-codec --disable-speex-aec
  --enable-darwin-ssl --enable-video --with-bcg729=<bcg729 install>`
- LDFLAGS: `-framework Network -framework Security -framework MetalKit`
- `PJMEDIA_RTP_PT_TELEPHONE_EVENTS=101` set to satisfy legacy SIP infrastructure
  expecting payload type 101 for DTMF telephone-events.

### config_site.h

The exact compile-time configuration also ships inside the artifact at
`Headers/pj/config_site.h` (fixes the ABI — do not override downstream):

```c
/* Start from the upstream sample configuration */
#define PJ_CONFIG_IPHONE 1
#include <pj/config_site_sample.h>

#define PJMEDIA_HAS_VIDEO                 1

/* Enable iOS video device backend */
#define PJMEDIA_VIDEO_DEV_HAS_IOS         1

/* Enable VideoToolbox codec. On iOS would require VideoToolbox.framework */
#define PJMEDIA_HAS_VID_TOOLBOX_CODEC 1

/* Enable UDP transport */
#define PJSIP_HAS_UDP_TRANSPORT 1

/* Enable TCP transport */
#define PJSIP_HAS_TCP_TRANSPORT 1

/* Enable TLS transport */
#define PJSIP_HAS_TLS_TRANSPORT 1
#define PJ_HAS_SSL_SOCK 1
#undef PJ_SSL_SOCK_IMP
#define PJ_SSL_SOCK_IMP PJ_SSL_SOCK_IMP_APPLE

/* Increase SIP message buffer */
#define PJSIP_MAX_PKT_LEN  16000  // or 12288; default is ~4000

/* Disable switching to TCP */
#define PJSIP_DONT_SWITCH_TO_TCP 1

/* Enable 729 Audio Codec */
#define PJMEDIA_HAS_INTEL_IPP_CODEC_G729     0
#define PJMEDIA_HAS_BCG729 1

/* Satisfy legacy infrastructure */
#define PJMEDIA_RTP_PT_TELEPHONE_EVENTS  101
```

## Toolchain & environment

Built 2026-06-12 on macOS with Xcode (versions not recorded — this build predates
the automated environment capture in `scripts/build.sh`).

## Artifacts

| File | Size | SHA-256 |
|------|------|---------|
| ios-arm64/libpjproject.a | 13115240 bytes | `da4f904c1434b120c965004c2ad8390f47041a04133904a632c5cbf244893777` |
| ios-arm64-simulator/libpjproject.a | 13160544 bytes | `797c7486c9c4a6dd3c14fc0182177701b49df1a24f1050cd2c41f1a913c9cad9` |

## Verification

Re-check this binary against its promised build parameters any time, on a Mac:

```bash
./scripts/verify-xcframework.sh Binaries/PJSIP.xcframework
```
