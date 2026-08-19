/*
 * config_site-ios.h — compile-time configuration for the iOS device and
 * simulator slices of PJSIP.xcframework.
 *
 * THIS FILE IS THE ABI. It is compiled into libpjproject.a and fixes struct
 * layouts, buffer sizes and which subsystems exist at all. A consumer cannot
 * override it: the binary is already built. Changing anything here means a
 * rebuild and a new package version (docs/Versioning.md).
 *
 * The macOS slice gets its own file (config_site-macos.h) rather than
 * TARGET_OS_* branches in this one — see TASK-code-swift-pjsip-macos-slice.md
 * §2 and docs/ARCHITECTURE.md decision 11. A shared file would hide which
 * preset a given binary actually got.
 *
 * HOUSE RULE: every #define below states WHY, and what it costs. A bare
 * "Disable switching to TCP" as the whole comment is what let PJSIP_DONT_SWITCH_TO_TCP sit
 * here for a year silently breaking every authenticated call over UDP.
 * A comment that names the tradeoff would have caught it.
 *
 * Line references are pjproject master @ 288de6142 (2026-08-19).
 */

/* ---------------------------------------------------------------------------
 * Upstream iOS preset
 *
 * Brings in PJMEDIA_AUDIO_DEV_HAS_COREAUDIO, iLBC, the float/CPU settings and
 * a set of deliberately small table sizes. Anything this preset decides that
 * we disagree with is #undef'd and redefined BELOW the include — the sample
 * uses bare #define, not #ifndef, so defining before it has no effect.
 *
 * Note what the preset also means: upstream ships Apple-platform features via
 * PJ_CONFIG_IPHONE, so they reach iOS only. The macOS header must set them by
 * hand (ARCHITECTURE.md decision 11).
 * ------------------------------------------------------------------------- */
#define PJ_CONFIG_IPHONE 1
#include <pj/config_site_sample.h>

/* ---------------------------------------------------------------------------
 * Capacity — raised above the iPhone preset
 *
 * The preset targets a 2012 iPhone. Both values below are #undef'd first
 * because config_site_sample.h has already defined them.
 * ------------------------------------------------------------------------- */

/* 8 accounts (= upstream default, pjsua.h:3969; the preset cuts it to 4).
 *
 * WHY: 4 is the whole account table, so the live SIP test suite could not add
 * a second provider pair without retiring an existing one.
 *
 * COST: pjsua_var.acc[] is a FIXED array inside the pjsua_data singleton
 * (pjsua_internal.h:619-623) and init_data() walks all of it at startup, so
 * four extra pjsua_acc entries are paid unconditionally, even with one account
 * configured. Measured against this build: sizeof(pjsua_acc) = 7160 B, so
 * +4 accounts = +28 KB, and sizeof(pjsua_data) is 106568 B in total.
 */
#undef  PJSUA_MAX_ACC
#define PJSUA_MAX_ACC 8

/* 8 simultaneous calls (the preset AND upstream both say 4 — pjsua.h:5928 —
 * so this is a departure from upstream, not a restoration).
 *
 * WHY: offhook's test05 saturates the limit at exactly 4 by design and has
 * no headroom to test anything past it; 4 is also low for a conference-capable
 * softphone.
 *
 * COST: unlike PJSUA_MAX_ACC this is only a ceiling — pjsua_var.calls is
 * pool-allocated at pjsua_init() to ua_cfg.max_calls (pjsua_core.c:110-122),
 * which pjsua_config_default() sets to this macro. Measured sizeof(pjsua_call)
 * = 22056 B, so leaving the default costs +86 KB. An app that wants the old
 * footprint can lower max_calls at runtime; it cannot raise it past this.
 */
#undef  PJSUA_MAX_CALLS
#define PJSUA_MAX_CALLS 8

/* 254 conference slots (= upstream default, pjsua.h:7980).
 *
 * WHY: this — not PJSUA_MAX_CALLS — is the real ceiling on a locally mixed
 * conference. The preset redefines it as (PJSUA_MAX_CALLS + 2*PJSUA_MAX_PLAYERS),
 * i.e. 12 before this file and 16 after, while every call, player and recorder
 * occupies a slot. Restoring the upstream default beats inventing a number.
 *
 * Note the macro is only the DEFAULT for pjsua_media_config.max_media_ports
 * (pjsua_core.c:442), and that runtime field is what actually sizes the bridge
 * (passed as param.max_slots, pjsua_aud.c:340). The two must nevertheless
 * agree, because pjsua_conf_get_active_ports() enumerates into a fixed
 * `unsigned ports[PJSUA_MAX_CONF_PORTS]` (pjsua_aud.c:870) — safe, since the
 * array size bounds the enumeration, but it silently UNDER-REPORTS once the
 * live bridge is larger than the compile-time value.
 *
 * COST: 8 bytes per unused slot in conf->ports (conference.c:801), plus
 * max_ports*8 bytes per LIVE port for its listener_slots/listener_adj_level
 * arrays (conference.c:460-468) — ~2 KB per live port at 254. The mixing hot
 * loop is bounded by port_cnt, not max_ports (conference.c:2773), so idle
 * slots cost no CPU.
 */
#undef  PJSUA_MAX_CONF_PORTS
#define PJSUA_MAX_CONF_PORTS 254

/* PJSIP_MAX_TSX_COUNT / PJSIP_MAX_DIALOG_COUNT stay at the preset's 31.
 * They look like caps but are pj_hash_create() bucket counts (hash.c:89-120,
 * sip_transaction.c:531): entries chain, nothing is ever rejected, and the
 * only consequence at 8 calls + 8 registering accounts is slightly longer
 * collision chains. PJSIP_MAX_TIMER_COUNT derives from them for its INITIAL
 * timer-heap size and resizes itself. Left alone deliberately. */

/* ---------------------------------------------------------------------------
 * Media
 * ------------------------------------------------------------------------- */

/* Video on. Upstream default is 0. Costs binary size and pulls in the
 * VideoToolbox / AVFoundation / MetalKit link dependencies the README lists.
 * Required by the softphone's video calling. */
#define PJMEDIA_HAS_VIDEO                 1

/* iOS capture/render backend (darwin_dev.m / ios_dev.m). Upstream enables it
 * under PJ_CONFIG_IPHONE only; set explicitly so the file states which backend
 * this slice has. The macOS slice needs PJMEDIA_VIDEO_DEV_HAS_AV_DEV instead —
 * a different backend, not a rename. */
#define PJMEDIA_VIDEO_DEV_HAS_IOS         1

/* Hardware H.264 via VideoToolbox. Upstream default 0. Software H.264
 * (openh264) is not built, so without this there is no H.264 at all.
 * Requires the app to link VideoToolbox.framework. */
#define PJMEDIA_HAS_VID_TOOLBOX_CODEC     1

/* G.729 via bcg729 (LGPL, statically folded into libpjproject.a — see
 * docs/ARCHITECTURE.md "what is inside the archive"). The Intel IPP codec is
 * explicitly off: it needs a commercial IPP that we do not ship, and leaving
 * both on makes which implementation answers ambiguous. */
#define PJMEDIA_HAS_INTEL_IPP_CODEC_G729  0
#define PJMEDIA_HAS_BCG729                1

/* RFC 4733 telephone-event payload type pinned to 101 (upstream default is
 * 96). WHY: legacy infrastructure on the provider side does not renegotiate
 * and expects 101; with the default, DTMF is signalled on a PT the far end
 * ignores. This is a wire-visible choice, not a preference. */
#define PJMEDIA_RTP_PT_TELEPHONE_EVENTS   101

/* Voice-activity-driven ducking of other audio while VoiceProcessingIO is
 * running, instead of a fixed duck for the whole call. Upstream default is 0
 * (pjmedia-audiodev/config.h:152) and config_site_sample.h already turns it on
 * for iOS; set explicitly because the macOS slice must NOT inherit it — the
 * maintainer deliberately left macOS on the old behaviour when merging our
 * pjproject#5178. Requires iOS 17 / macOS 14; a no-op below that.
 *
 * NOT YET LISTENED TO. The upstream PR notes record that no listening test was
 * ever done. See swift-pjsua/Upstream/pjproject-5178-*.md. */
#define PJMEDIA_AUDIO_DEV_COREAUDIO_ADVANCED_DUCKING 1

/* ---------------------------------------------------------------------------
 * Transports
 * ------------------------------------------------------------------------- */

/* All three transports compiled in. UDP and TCP are upstream defaults already;
 * stated here because a SIP stack that silently lost one of them is a very
 * confusing thing to debug, and because the macOS header must match. */
#define PJSIP_HAS_UDP_TRANSPORT 1
#define PJSIP_HAS_TCP_TRANSPORT 1

/* TLS via Apple's Network.framework (PJ_SSL_SOCK_IMP_APPLE), NOT OpenSSL and
 * NOT the deprecated SecureTransport backend. WHY: no OpenSSL to vendor,
 * update or license, and the App Store treats the system TLS stack as the
 * expected one. The #undef is required — pj/config.h has already defaulted
 * PJ_SSL_SOCK_IMP by the time this file is read. */
#define PJSIP_HAS_TLS_TRANSPORT 1
#define PJ_HAS_SSL_SOCK 1
#undef  PJ_SSL_SOCK_IMP
#define PJ_SSL_SOCK_IMP PJ_SSL_SOCK_IMP_APPLE

/* 16000-byte SIP message buffer (upstream default ~4000).
 * WHY: real-world INVITEs with a full video SDP, ICE candidates, long Route
 * sets and Authorization headers exceed 4 KB, and PJSIP_MAX_PKT_LEN is a hard
 * truncation point, not a soft one.
 * COST: this is a per-transport receive-buffer size — it is ABI, and it is
 * why a consumer must never override this header. */
#define PJSIP_MAX_PKT_LEN 16000

/* PJSIP_DONT_SWITCH_TO_TCP is deliberately NOT defined (upstream default 0).
 *
 * It used to be 1 here, commented only "Disable switching to TCP".
 * That single line disabled RFC 3261 §18.1.1 outright: sip_util.c:1419 guards
 * the ENTIRE block — size check and TCP-transport lookup alike — on
 * disable_tcp_switch == 0. The consequence was that no authenticated call
 * could be placed over a UDP transport at all: adding the digest pushes the
 * INVITE past the 1300-byte threshold, it went out on UDP anyway, fragmented,
 * and was dropped. Measured at two independent providers (Flexisip
 * 1322→1634 B, antisip 1289→1578 B). See offhook/docs/SIP-Test-Infrastructure.md
 * §6. Do not re-add it; if a specific peer ever needs it, it is runtime
 * settable via pjsip_cfg()->endpt.disable_tcp_switch. */

/* PJSIP_TCP_KEEP_ALIVE_INTERVAL is deliberately left at its default. It is
 * runtime-settable (pjsip_cfg()->tcp.keep_alive_interval) and is the mechanism
 * behind the 126 s transport-death detection measured in
 * swift-pjsua/docs/Call-Termination-Paths.md §4.1 — changing it at build time
 * silently moves a number other documents quote. */

/* ---------------------------------------------------------------------------
 * Deliberately NOT enabled — reasoning in docs/Build-Time-Feature-Gates.md
 *
 *   PJMEDIA_HAS_RTCP_XR / PJMEDIA_STREAM_ENABLE_XR — RFC 3611 extended
 *     reports. Decided 2026-08-17: off. Adds `a=rtcp-xr` to every SDP (a
 *     signalling change every registrar and SBC sees) in exchange for a debug
 *     statistic that pjmedia_jb_state.avg_burst already approximates.
 *   PJMEDIA_STREAM_ENABLE_KA — RTP keep-alive. Transmitter only; it does NOT
 *     buy media-liveness detection. Undecided; enable if NAT bindings are
 *     observed expiring mid-call.
 *   Opus — absent, see docs/Codec-Coverage.md. Separate branch, separate task.
 * ------------------------------------------------------------------------- */
