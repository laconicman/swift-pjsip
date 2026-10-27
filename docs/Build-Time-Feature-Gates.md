# Build-time feature gates — what `config_site.h` decides for everyone downstream

`swift-pjsip` ships a **prebuilt** `.xcframework`. Every `#define` in
[`scripts/config_site.h`](../scripts/config_site.h) is therefore baked into the binary: consumers
cannot enable a compiled-out feature at runtime, no matter what the pjsua API appears to offer.

This file records the gates that are **off**, what each one would buy, and what enabling it costs —
so a future session does not spend an afternoon discovering that a runtime knob is inert because the
code behind it was never compiled.

**Source:** local `pjproject` fork at **`cb0544e0d`** (upstream master of the same day), read
directly. Line numbers are that commit. Established 2026-08-17 by the call-quality and
call-lifecycle passes (`../../swift-pjsua/docs/Call-Termination-Paths.md`,
`../../offhook/docs/Call-Quality-Statistics.md`).
Re-checked for `0.3.0` against master `bd69054a6` (2026-10-09): none of the gates below changed
its default. What did change is the conference bridge, below.

---

## What we currently set

`scripts/config_site-ios.h` starts from `PJ_CONFIG_IPHONE` + `config_site_sample.h` and sets: video
on (`PJMEDIA_HAS_VIDEO`, iOS video device, VideoToolbox codec), UDP/TCP/TLS transports with
`PJ_SSL_SOCK_IMP_APPLE` (deliberately, not the deprecated Darwin/SecureTransport backend), BCG729,
Opus (`PJMEDIA_HAS_OPUS_CODEC`, since `0.4.0`),
`PJMEDIA_RTP_PT_TELEPHONE_EVENTS 101`, CoreAudio advanced ducking, and `PJSIP_MAX_PKT_LEN 16000`.
`PJSIP_DONT_SWITCH_TO_TCP` is **not** set — it used to be, and it disabled RFC 3261 §18.1.1 outright,
so no authenticated call could be placed over UDP.

### Two literals, and why only two

A value here is only worth overriding when upstream's own default is **insufficient**. Restating a
default as a literal reads as harmless and is not: it pins the number against a future upstream
release that raises it, and it hides which values we actually have an opinion about.

So the capacity block sets exactly two numbers and hands the rest back:

| Macro | What we do | Why |
|---|---|---|
| `PJSIP_MAX_PKT_LEN` | **16000** | Upstream's ~4000 truncates real INVITEs carrying a video SDP, ICE candidates, a long Route set and an Authorization header. A hard truncation point, not a soft one. |
| `PJSUA_MAX_CALLS` | **8** | Upstream and the preset both say 4, and 4 is not enough — the live suite's test05 saturates it by design with no headroom, and 4 is low for a conference-capable softphone. The one place we knowingly pin above upstream. |
| `PJSUA_MAX_ACC` | bare `#undef` | Only the *preset* was in the way (it cuts upstream's 8 to 4). Upstream's default is already what we want, so take whatever it is. |
| `PJSUA_MAX_CONF_PORTS` | bare `#undef` | Same shape: the preset replaces upstream's 254 with `PJSUA_MAX_CALLS + 2*PJSUA_MAX_PLAYERS`. |

The bare `#undef` matters because `pjsua.h` guards each of these with `#ifndef` — undoing the preset
and stopping there inherits upstream's number, today's and tomorrow's.

### Left at upstream's default, and changed by upstream: the conference bridge

From `0.3.0` the artifact mixes audio in `conf_thread.c`, not `conference.c`.
[pjproject#5297](https://github.com/pjsip/pjproject/pull/5297) made the parallel bridge the default
backend wherever there are threads. On iOS, `PJMEDIA_CONF_THREADS` defaults to 1, so pjsua asks
for no worker threads and the bridge runs non-parallel: mixing stays in the sound device's
`get_frame()` thread, and the new `pjsua_media_config.conf_thread_prio` (applied to worker threads
only) has nothing to act on.

What an application can observe is timing, in two places:

- Queued connect, disconnect and remove operations are applied after the tick's mix rather than
  before it, so a mute (a disconnect from slot 0) takes effect one 20 ms frame later.
- A hangup's BYE now goes out before the call's port has left the bridge; on 0.2.1 it went out
  after. In the Offhook live suite, four calls tore down in 11 ms where they had taken ~330 ms.
  A call slot stays taken until its BYE transaction ends, though, so a call placed in the same
  instant can meet `PJ_ETOOMANY`. That is how the suite found this: a test dialling right after
  another had filled the call table started failing.

Pinning
`PJMEDIA_CONF_SERIAL_BRIDGE_BACKEND` would keep the old file, at the cost of running a backend
upstream no longer defaults to; we do not.
The line-level reasoning is in `scripts/config_site-ios.h`.

### Compiled in since `0.3.0`, off unless the application turns them on

Not build gates, but easy to mistake for features the binary lacks:

- **Server failover** (`PJSIP_SERVER_FAILOVER`, default 0; runtime `pjsip_cfg()` setting):
  remember failed servers and retry a request that gets no answer or a 503 on the next address
  ([pjproject#5293](https://github.com/pjsip/pjproject/pull/5293)).
- **System-resolver fallback** (`PJ_DNS_RESOLVER_SYS_FALLBACK`, default off;
  `pj_dns_settings.sys_fallback`): resolve A/AAAA with `getaddrinfo()` while no nameserver
  answers ([pjproject#5303](https://github.com/pjsip/pjproject/pull/5303)). When on, it runs lookups
  in up to `PJ_DNS_RESOLVER_SYS_FALLBACK_THREADS` (4) resolver threads.

Everything below is **not** set, and inherits an upstream default of `0`.

---

## The gates that are off

### `PJMEDIA_HAS_RTCP_XR` — RFC 3611 extended reports

- **Default `0`** (`pjmedia/include/pjmedia/config.h:644-645`). A second gate,
  `PJMEDIA_STREAM_ENABLE_XR`, is also `0` (`:656-657`), and the runtime field
  `pjsua_acc_config.enable_rtcp_xr` (`pjsua.h:5188`) is derived from the **product** of the two at
  `pjsua_core.c:408` — so the runtime knob is permanently `0` in our binary. Three gates, all off.
- **Buys:** burst/gap density and duration, discard rate, and the RFC 3611 Appendix A.4 Markov loss
  model — the only way to distinguish clumped loss from scattered loss, which is perceptually a
  large difference and invisible in plain `pjmedia_rtcp_stat`.
- **Does not buy a MOS.** pjmedia never computes R-factor or MOS; it initialises them to RFC 3611's
  `127` = unavailable and only relays a peer's values or ones the app pushes in
  (`pjmedia/src/pjmedia/rtcp_xr.c:88-91`, `:382-385`, `:801-830`).
- **Costs:** an `.xcframework` rebuild, plus — for the third gate — `a=rtcp-xr` added to the SDP of
  every call (`pjsua_media.c:3352-3360`). That is a **signalling change visible to every registrar
  and SBC**, in exchange for a debug statistic.
- **Decision (2026-08-17): leave off.** `pjmedia_jb_state.avg_burst` is already populated in
  `pjsua_stream_stat.jbuf` and approximates the same signal for free. Reasoning:
  `../../offhook/docs/Call-Quality-Statistics.md` §6.

### `PJMEDIA_SRTP_HAS_DTLS` — DTLS-SRTP keying

- **Default `0`** (`pjmedia/include/pjmedia/config.h:1190-1192`), and we take that default. The
  sibling gate `PJMEDIA_SRTP_HAS_SDES` is `1` (`:1180-1182`), as is `PJMEDIA_HAS_SRTP` (`:1170-1171`).
  Measured on the shipped artefact: 401 `srtp_*` symbols, 30 SDES, and **zero OpenSSL** — DTLS is
  present only as its disabled stubs.
- **So SRTP works and DTLS-SRTP does not.** Media encryption is available today through **SDES**,
  which carries the key in the SDP. That is why the binary needs no crypto library: SDES leans on
  the signalling channel being secure rather than doing its own key agreement.
- **Buys:** the other keying method — a DTLS handshake on the media path, so the key never appears
  in signalling. Required for WebRTC interop, and preferred or mandated by some providers.
- **Costs: OpenSSL, unavoidably.** `pjmedia/src/pjmedia/transport_srtp_dtls.c` includes
  `openssl/bn.h`, `ec.h`, `rsa.h`, `ssl.h` unconditionally at the top, so turning this gate on
  without linking OpenSSL does not compile. This is independent of `PJ_SSL_SOCK_IMP`: our SIP-TLS
  going through Apple's Network framework does not help here, and `aconfigure.ac:2191` says as much
  ("DTLS requires OpenSSL").
- The real cost is not the build. It is inheriting OpenSSL's CVE cadence into a binary we ship, plus
  the size, in exchange for one keying method.
- **Decision (2026-09-02): leave off.** Revisit when a target provider actually requires DTLS-SRTP;
  see `../../offhook/docs/Roadmap.md` for the trigger and `../../offhook/docs/Tech-Debt.md` OH-10
  for what SDES-only costs us meanwhile. Note upstream is actively working this area
  (pjproject#5231 modernised the DTLS-SRTP certificate to the OpenSSL 3.0 key-generation API),
  so the ground may move.

### `PJMEDIA_STREAM_ENABLE_KA` — RTP keep-alive

- **Default `0`** (`pjmedia/include/pjmedia/config.h:1441-1442`); interval 5 s, start count 2
  (`:1452-1467`).
- **Buys:** *transmission* of keep-alive packets during silence, so NAT bindings and stateful
  firewall pinholes survive a quiet stretch. Relevant when VAD is on or the far end goes silent.
- **Does NOT buy liveness detection.** This is the most important line in this file. It is a
  transmitter only — **nothing in pjmedia observes inbound RTP silence**, at any setting. If you are
  looking for "tell me the media died", this is not it and no other build flag is either; see
  `../../swift-pjsua/docs/Call-Termination-Paths.md` §4.
- **Costs:** a small constant packet rate per stream during silence.
- **Status: undecided.** Worth enabling if we see NAT bindings expiring mid-call; not urgent.

### Session timers (RFC 4028)

- Not a `config_site.h` gate — compiled in, and configured **at runtime** via
  `pjsua_acc_config.use_timer`, default `PJSUA_SIP_TIMER_OPTIONAL` (`pjsua.h:2688-2690`), with
  `Session-Expires` defaulting to 1800 s (`pjsip/include/pjsip/sip_config.h:1526-1527`).
- Noted here because it is the **only backstop** that eventually notices a dialog whose transport
  died silently, and "optional" means "only if the peer supports it". At the 1800 s default the
  refresh lands up to ~15 minutes late. Do not treat it as detection; see OH-10.

### ICE / STUN / TURN

- Compiled in; unexposed by the engine (`swift-pjsua` TD-14) and unconfigured by the app
  (`offhook` OH-4).
- Worth recording alongside the above because **ICE keep-alive failure is the stack's only
  continuous media-liveness signal** (`pjsua_media.c:1107-1133`, delivered via
  `on_call_media_transport_state` / `on_ice_transport_error`). Enabling ICE would buy connectivity
  monitoring as a side effect of NAT traversal.

### Codecs

**Opus is on since `0.4.0`** (`PJMEDIA_HAS_OPUS_CODEC 1` + `--with-opus`, libopus `v1.6.1`). Only
the gate is set — the `PJMEDIA_CODEC_OPUS_DEFAULT_*` values stay at upstream's (sample rate 48000,
bitrate 0 = auto, complexity 5, CBR off i.e. VBR; `pjmedia-codec/config.h:513-555`) and are
runtime-tunable per endpoint via `pjmedia_codec_opus_set_config()`. Two runtime facts an
application still has to arrange itself: Opus is `opus/48000/2` on the wire while pjsua's bridge
defaults to 16 kHz (`PJSUA_DEFAULT_CLOCK_RATE`), so it resamples every frame unless the app raises
`pjsua_media_config.clock_rate`/`snd_clock_rate` to 48000; and offer order is codec priority, so
"prefer Opus" is `pjsua_codec_set_priority`, not a build switch. Full story:
[Codec-Coverage](./Codec-Coverage.md).

Relevant to quality work beyond NAT and liveness: G.711 has no published `Ie`/`Bpl` sensitivity
problem, but G.722's E-model impairment values are not tabulated in the sources we found at all,
which is one of the reasons the quality design refuses to compute a MOS.

---

## Rule of thumb

Before designing anything on a pjsua *runtime* setting, check whether a `config.h` macro gates the
code behind it. Three of the four items above look like runtime features from the pjsua header and
are decided here, at build time, for every consumer of the binary. `pjsua_acc_config.enable_rtcp_xr`
is the cautionary example: a perfectly ordinary-looking `pj_bool_t` in a public config struct that
cannot be set to anything but `0` in our build.

---

## See Also

- [ARCHITECTURE](./ARCHITECTURE.md) · [Codec-Coverage](./Codec-Coverage.md)
- `../../swift-pjsua/docs/Call-Termination-Paths.md` — why liveness detection has no build-time answer
- `../../offhook/docs/Call-Quality-Statistics.md` §6 — the RTCP XR decision in full
