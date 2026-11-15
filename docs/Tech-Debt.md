# Tech debt & tracked deferrals

A register of known shortcuts, deferrals, and obligations in `swift-pjsip`. Each item is
intentional and tracked — not an accidental gap. `Build-Time-Feature-Gates.md` holds the full
behavioural documentation of the `config_site.h` decisions; this file is the "what we knowingly
owe" side of them.

Status legend: **open** (owed), **blocked-upstream** (owed, waiting on pjsip/pjproject),
**accepted** (a cost taken knowingly, restated so it is not re-litigated each release).

---

## TD-1 — `PJMEDIA_CONF_BACKEND` pinned to the serial bridge · **open — upstream fix landed, awaiting vendor bump**

Since `0.7.0`, `scripts/config_site-ios.h` defines `PJMEDIA_CONF_BACKEND` as
`PJMEDIA_CONF_SERIAL_BRIDGE_BACKEND`, off the `conf_thread.c` parallel default the artifact ran
since `0.3.0` ([pjproject#5297](https://github.com/pjsip/pjproject/pull/5297)).

**Why it is owed, not chosen.** The pin exists because `conf_thread.c`'s `mix_and_transmit()`
asserts `listener->transmitter_cnt == 1 && listener->last_timestamp.u64 != timestamp->u64`
(`conf_thread.c:4507` @ `bf14c2e2c`), and that invariant is reachable from legal pjsua use:
every sound-device (re)open starts a new `pjmedia_clock` at timestamp 0 while
`conf_port->last_timestamp` persists, so a listener skipped for a few ticks around a reopen is
mixed again exactly on its stale timestamp. `conference.c` holds no such invariant — the pin
removes the assert rather than relocating it. Full analysis, both reproduction programs and
fix candidates live in
[laconicman/swift-pjsip#26](https://github.com/laconicman/swift-pjsip/issues/26).

**What it costs.** We diverge from upstream's default backend: fixes and improvements that land
in `conf_thread.c` do not reach consumers, and each release must re-verify that the serial path
still matches its documented behaviour. The pin also flips op-queue and BYE ordering back to the
pre-`0.3.0` semantics — currently treated as a plus (the `0.2.1`-era order), but it is a
divergence a future upgrade has to re-decide, not an invisible one.

**Update 2026-11-15 — upstream fixed it before our report was filed.**
[pjproject#5377](https://github.com/pjsip/pjproject/pull/5377) (`ddf55c302`, nanangizz,
2026-11-05) replaced `last_timestamp` with a bridge-owned tick counter (`last_tick`,
incremented in `get_frame()`) at all three sites our analysis flagged — the single-transmitter
assert, the multi-transmitter sum-path check, and `write_port()`'s heartbeat check — and added
`clock_restart_test` to `conf_test` covering exactly this scenario (one and two transmitters,
timestamp restart). The maintainer kept the assert: on a bridge-owned tick it is again a
genuine invariant, so the draft's "downgrade to a logged check" candidate is dropped.
Nothing further is owed upstream for this defect.

**Resolution path.**

1. ~~File the drafted upstream report~~ — superseded by #5377; the draft stays as internal
   evidence (not filed, not needed).
2. When a pjproject ≥ `ddf55c302` is vendored (current upstream master `d78f0ddc7` also carries
   publish-client thread-safety #5383, failed re-INVITE rollback #5355, and the
   unregistered-account fix #5362 — all independently wanted): re-evaluate the pin. Unpinning
   is not automatic — the serial bridge's op-queue ordering is what `0.2.1`-era consumers were
   built against, so "stay serial deliberately" is a legitimate end state. The decision must be
   made with the fix vendored and device-tested, not assumed now. Until then the pin stays —
   `0.7.0` is mid device-validation and must not churn.

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
