# Tech debt & tracked deferrals

A register of known shortcuts, deferrals, and obligations in `swift-pjsip`. Each item is
intentional and tracked — not an accidental gap. `Build-Time-Feature-Gates.md` holds the full
behavioural documentation of the `config_site.h` decisions; this file is the "what we knowingly
owe" side of them.

Status legend: **open** (owed), **blocked-upstream** (owed, waiting on pjsip/pjproject),
**accepted** (a cost taken knowingly, restated so it is not re-litigated each release).

---

## TD-1 — `PJMEDIA_CONF_BACKEND` pinned to the serial bridge · **resolved in `0.8.0`**

`0.7.0` defined `PJMEDIA_CONF_BACKEND` as `PJMEDIA_CONF_SERIAL_BRIDGE_BACKEND` in
`scripts/config_site-ios.h`, off the `conf_thread.c` parallel default the artifact ran
since `0.3.0` ([pjproject#5297](https://github.com/pjsip/pjproject/pull/5297)). `0.8.0`
vendors pjproject `48290cd9`, which carries
[pjproject#5377](https://github.com/pjsip/pjproject/pull/5377) (`ddf55c302`) — the bridge-owned
`last_tick` counter that removed the reachable timestamp-restart assert — so the pin is
dropped and the artifact is back on upstream's parallel default. Op-queue and BYE ordering
return to the `0.3.0`–`0.6.0` semantics (see `Build-Time-Feature-Gates.md`).

**Why the pin existed.** The parallel bridge's `mix_and_transmit()` asserted
`listener->transmitter_cnt == 1 && listener->last_timestamp.u64 != timestamp->u64`, reachable
from legal pjsua use: every sound-device (re)open starts a new `pjmedia_clock` at timestamp 0
while `conf_port->last_timestamp` persists. `conference.c` held no such invariant. Full
analysis, both reproduction programs and fix candidates live in
[laconicman/swift-pjsip#26](https://github.com/laconicman/swift-pjsip/issues/26).

**Cost while pinned.** Divergence from upstream's default backend: `conf_thread.c` fixes did
not reach consumers, and each release re-verified the serial path. The pin also flipped
op-queue and BYE ordering back to the pre-`0.3.0` semantics — treated as a plus at the time
(the `0.2.1`-era order), but a divergence a future upgrade had to re-decide.

## TD-2 — `PJ_DEBUG 0` baked into the release artifact · **open**

Since `0.7.0`, `scripts/config_site-ios.h` defines `PJ_DEBUG 0`. Through `0.6.0` every
`pj_assert` was `abort()`; now a failed assert emits a level-1 `Assert failed:` line
synchronously from the asserting frame and execution continues. The abort-or-continue policy
moved to the consumer's log callback.

**What it costs** (all recorded in `Build-Time-Feature-Gates.md` §`PJ_DEBUG`): `pj_mutex_t`
loses owner/nesting bookkeeping (`PJ_DEBUG_MUTEX` follows `PJ_DEBUG`), asserts go silent on
threads that never registered with PJLIB, and an internal invariant violation now *continues* —
a consumer that does not watch level-1 `Assert failed:` lines sees nothing at all. The binary
also grew ~10 MB per slice with `-g`, a trade taken for `file.c:line` in crash reports.

**Resolution path.** `PJ_DEBUG 0` for the release artifact is a settled decision, not a
placeholder — aborting on the sound/clock thread was the crash being fixed. What remains open:

- whether a **debug-flavored** artifact (`PJ_DEBUG 1`, or a second xcframework variant) is worth
  producing so development and fuzzing builds keep the abort behaviour the library was designed
  around;
- ~~re-checking if upstream downgrades the reachable production asserts~~ — settled: #5377
  fixed the reachable assert rather than downgrading it, and the assert now guards a genuine
  (bridge-owned) invariant, so `PJ_DEBUG 1` remains fatal on real violations. The flavor
  question stands on its own merits.

---

## See Also

- [Build-Time-Feature-Gates](./Build-Time-Feature-Gates.md) — the behavioural record behind both items
- [ARCHITECTURE](./ARCHITECTURE.md) · [Versioning](./Versioning.md)
- [laconicman/swift-pjsip#26](https://github.com/laconicman/swift-pjsip/issues/26) — the upstream
  resolution both items track
