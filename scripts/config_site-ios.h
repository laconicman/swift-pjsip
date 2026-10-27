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
 * Line references are pjproject master @ 1f0ebf2eb (2026-10-27). Each one
 * carries the `token` that must sit at that line; scripts/check-cites.sh
 * verifies them against the tree build.sh is about to compile, so the line
 * above is checked on every download rather than claimed by the last edit.
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
 * Capacity — the 2012-iPhone preset's cuts, undone
 *
 * All three are #undef'd first because config_site_sample.h has already
 * defined them; the sample uses bare #define, so defining before it has no
 * effect.
 *
 * Note the shape of the first and third: an #undef with NO redefinition. That
 * hands the macro back to pjsua.h's own #ifndef default, so if upstream ever
 * raises one of these we inherit the new value. Restating today's default as a
 * literal would look identical in this build and silently cap a future one —
 * and it would be an override we cannot justify, since the only thing wrong
 * with those two was the preset lowering them. Only override a default that is
 * actually insufficient; PJSUA_MAX_CALLS and PJSIP_MAX_PKT_LEN are the two that
 * clear that bar, and both say so where they are set.
 * ------------------------------------------------------------------------- */

/* Accounts: whatever upstream defaults to — 8 as of 2.17/master,
 * pjsua-lib/pjsua.h:4079 `define PJSUA_MAX_ACC`; the preset cuts it to 4.
 *
 * WHY: 4 is the whole account table, so the live SIP test suite could not add
 * a second provider pair without retiring an existing one. Upstream's own
 * default is already enough — the preset is the only thing in the way.
 *
 * COST: pjsua_var.acc[] is a FIXED array inside the pjsua_data singleton
 * (pjsua_internal.h:678 `acc[PJSUA_MAX_ACC]`) and init_data() walks all of
 * it at startup, so four extra pjsua_acc entries are paid unconditionally,
 * even with one account configured. Measured against this build:
 * sizeof(pjsua_acc) = 7168 B, so +4 accounts = +28 KB, and sizeof(pjsua_data)
 * is 106680 B in total.
 */
#undef  PJSUA_MAX_ACC

/* 8 simultaneous calls (the preset AND upstream both say 4 —
 * pjsua-lib/pjsua.h:6076 `define PJSUA_MAX_CALLS` — so this is a departure
 * from upstream, not a restoration, and the only literal in this section).
 *
 * WHY: 4 is genuinely insufficient, which is what earns the override — the
 * live suite's test05 saturates the limit at exactly 4 by design and has no
 * headroom to test anything past it, and 4 is low for a conference-capable
 * softphone. It does pin: were upstream to raise its own default past 8, this
 * line would hold us at 8 until someone edits it.
 *
 * COST: unlike PJSUA_MAX_ACC this is only a ceiling — pjsua_var.calls is
 * pool-allocated at pjsua_init() to ua_cfg.max_calls
 * (pjsua_call.c:245-250 `sizeof(pjsua_call) *`), which pjsua_config_default()
 * sets to this macro (pjsua_core.c:115 `cfg->max_calls = PJSUA_MAX_CALLS`).
 * Measured sizeof(pjsua_call) = 22328 B, so leaving the default costs
 * +87 KB. An app that wants the old footprint can lower max_calls at runtime;
 * it cannot raise it past this.
 */
#undef  PJSUA_MAX_CALLS
#define PJSUA_MAX_CALLS 8

/* Conference slots: whatever upstream defaults to — 254 as of 2.17/master,
 * pjsua-lib/pjsua.h:8261 `define PJSUA_MAX_CONF_PORTS`.
 *
 * WHY: this — not PJSUA_MAX_CALLS — is the real ceiling on a locally mixed
 * conference. The preset replaces it with (PJSUA_MAX_CALLS + 2*PJSUA_MAX_PLAYERS),
 * i.e. 16 with the calls value above, while every call, player and recorder
 * occupies a slot. Handing it back to upstream beats inventing a number.
 *
 * Note the macro is only the DEFAULT for pjsua_media_config.max_media_ports
 * (pjsua_core.c:450 `cfg->max_media_ports = PJSUA_MAX_CONF_PORTS`), and that
 * runtime field is what actually sizes the bridge
 * (pjsua_aud.c:349 `param.max_slots`). The two must nevertheless agree,
 * because pjsua_conf_get_active_ports() enumerates into a fixed array
 * (pjsua_aud.c:944 `ports[PJSUA_MAX_CONF_PORTS]`) — safe, since the array
 * size bounds the enumeration, but it silently UNDER-REPORTS once the live
 * bridge is larger than the compile-time value.
 *
 * COST: 8 bytes per unused slot in conf->ports
 * (conf_thread.c:1114-1119 `conf->ports =`), plus max_ports*8 bytes per LIVE
 * port for its listener_slots/listener_adj_level arrays
 * (conf_thread.c:711-719 `conf_port->listener_adj_level =`) — ~2 KB per live
 * port at 254. The mixing hot loop walks the active ports only, not max_ports
 * (conf_thread.c:4085-4094 `conf->active_ports_idx`), so idle slots cost no
 * CPU. (conf_thread.c, not conference.c: see the PJMEDIA_CONF_BACKEND note
 * below.)
 */
#undef  PJSUA_MAX_CONF_PORTS

/* PJSIP_MAX_TSX_COUNT / PJSIP_MAX_DIALOG_COUNT stay at the preset's 31.
 * They look like caps but are pj_hash_create() bucket counts
 * (hash.c:254-282 `pj_hash_create`,
 * sip_transaction.c:534 `pjsip_cfg()->tsx.max_count`): entries chain,
 * nothing is ever rejected, and the
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

/* Opus via libopus (BSD-3-Clause + the Opus patent licence; statically folded
 * into libpjproject.a like bcg729 — see docs/ARCHITECTURE.md "what is inside
 * the archive"). Upstream's configure AC_DEFINE lands in
 * pjmedia-codec/config_auto.h, whose template guards it with
 * #ifndef PJMEDIA_HAS_OPUS_CODEC — so this line wins silently (same value, no
 * redefinition warning). It exists because the house rule is that every
 * feature macro is stated explicitly per slice; what actually proves libopus
 * was found and linked is the configure-log assertion in build.sh and the
 * verifier's symbol checks, not this macro.
 *
 * COST: libopus.a is 619 KB (device) / 654 KB (simulator), adding 138 members
 * to libpjproject.a — 586 total vs 448 on 0.3.1 (+1.5 MB merged; the delta is
 * libopus plus the 36 upstream commits' code changes, not libopus alone).
 * Runtime shape (clock rate, bitrate, complexity, VBR)
 * is NOT pinned here — PJMEDIA_CODEC_OPUS_DEFAULT_* stay at upstream defaults
 * (48000 / 0 = auto / 5 / VBR) and are settable via
 * pjmedia_codec_opus_set_config(). */
#define PJMEDIA_HAS_OPUS_CODEC            1

/* RFC 4733 telephone-event payload type pinned to 101 (upstream default is
 * 96). WHY: legacy infrastructure on the provider side does not renegotiate
 * and expects 101; with the default, DTMF is signalled on a PT the far end
 * ignores. This is a wire-visible choice, not a preference. */
#define PJMEDIA_RTP_PT_TELEPHONE_EVENTS   101

/* Voice-activity-driven ducking of other audio while VoiceProcessingIO is
 * running, instead of a fixed duck for the whole call. Upstream default is 0
 * (pjmedia-audiodev/config.h:153 `COREAUDIO_ADVANCED_DUCKING 0`) and
 * config_site_sample.h already turns it on
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
 * It bounds received messages too: rdata's packet buffer is
 * char[PJSIP_MAX_PKT_LEN] (sip_transport.h:360 `packet[PJSIP_MAX_PKT_LEN]`),
 * and a TCP message that fills it is dropped, the rest of the stream with it
 * (sip_transport.c:2293-2301 `dd_status = PJSIP_ERXOVERFLOW`). A REGISTER 200
 * lists every binding of the AOR,
 * and with long +sip.instance values that grows fast: in a lab run, a 200
 * that still listed the bindings of a length test (instance values of up to
 * 2048 characters, ~4.3 KB together) came to ~4.7 KB and was lost at
 * upstream's 4000, so the registration timed out with 408. 16000 covers
 * that with room to spare; realistic UUID instance values (~47 bytes) do not
 * come close.
 * COST: this is a per-transport receive-buffer size — it is ABI, and it is
 * why a consumer must never override this header. */
#define PJSIP_MAX_PKT_LEN 16000

/* PJSIP_DONT_SWITCH_TO_TCP is deliberately NOT defined (upstream default 0).
 *
 * It used to be 1 here, commented only "Disable switching to TCP".
 * That single line disabled RFC 3261 §18.1.1 outright: the guard at
 * sip_util.c:1430 `disable_tcp_switch==0` covers the ENTIRE block — size
 * check and TCP-transport lookup alike. The consequence was that no
 * authenticated call
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

/* PJMEDIA_CONF_BACKEND and PJMEDIA_CONF_THREADS are deliberately left at their
 * defaults. Since pjproject#5297 the default backend is the parallel bridge
 * (conf_thread.c) wherever there are threads, so this slice no longer builds
 * conference.c. PJMEDIA_CONF_THREADS defaults to 1 under TARGET_OS_IPHONE
 * (pjmedia/config.h:178-188 `ifndef PJMEDIA_CONF_THREADS`), so pjsua passes
 * worker_threads 0 (pjsua_aud.c:355 `param.worker_threads`) and the bridge
 * runs with is_parallel false (conf_thread.c:1108 `conf->is_parallel`): no
 * worker threads are created, mixing stays in the sound device's get_frame()
 * thread, and conf_thread_prio, which only applies to workers, does nothing.
 * What an application can observe is timing. The parallel bridge applies
 * queued connect/disconnect/remove operations after the tick's mix
 * (conf_thread.c:3929-3936 `handle_op_queue(conf)`), where conference.c
 * applied them before it (conference.c:3266-3273 `handle_op_queue(conf)`), so
 * they take effect one frame (20 ms) later. And a
 * hangup's BYE now leaves before the call's port has left the bridge; on
 * 0.2.1 it left after. In a live suite four calls tore down in 11 ms instead of
 * ~330 ms, while each call slot stays taken until its BYE transaction ends, so
 * a call placed right after a mass hangup can meet PJ_ETOOMANY.
 * Pinning PJMEDIA_CONF_SERIAL_BRIDGE_BACKEND would keep the old file at the
 * cost of running a backend upstream no longer defaults to. */

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
 * ------------------------------------------------------------------------- */
