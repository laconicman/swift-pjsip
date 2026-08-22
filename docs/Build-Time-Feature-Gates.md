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

---

## What we currently set

`scripts/config_site-ios.h` starts from `PJ_CONFIG_IPHONE` + `config_site_sample.h` and sets: video
on (`PJMEDIA_HAS_VIDEO`, iOS video device, VideoToolbox codec), UDP/TCP/TLS transports with
`PJ_SSL_SOCK_IMP_APPLE` (deliberately, not the deprecated Darwin/SecureTransport backend), BCG729,
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

Opus is absent from the current binary — see [Codec-Coverage](./Codec-Coverage.md). Relevant to
quality work beyond NAT and liveness: G.711 has no published `Ie`/`Bpl` sensitivity problem, but
G.722's E-model impairment values are not tabulated in the sources we found at all, which is one of
the reasons the quality design refuses to compute a MOS.

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
