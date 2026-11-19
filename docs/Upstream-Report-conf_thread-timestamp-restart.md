# SUPERSEDED — not filed, not needed. Upstream report for pjsip/pjproject

> Status: superseded by [pjproject#5377](https://github.com/pjsip/pjproject/pull/5377)
> (`ddf55c302`, nanangizz, 2026-11-05) — the maintainer implemented this report's primary fix
> candidate verbatim (bridge-owned `last_tick` at all three sites + `clock_restart_test`)
> before this was ever filed. Kept as evidence and analysis only; do not file.
> Text below is the intended issue body as drafted; nothing in it names the consuming
> application.

**Title:** `conf_thread.c`: `mix_and_transmit()` single-transmitter assert is reachable when the
sound device is (re)opened — the new `pjmedia_clock` restarts timestamps at 0 while
`conf_port->last_timestamp` persists

## Summary

With the parallel conference bridge (`PJMEDIA_CONF_PARALLEL_BRIDGE_BACKEND`, the default since
#5297) running in its non-parallel mode (`worker_threads == 0`, as pjsua-lib configures it on
iPhone where `PJMEDIA_CONF_THREADS` defaults to 1), `mix_and_transmit()` asserts on the
single-transmitter path:

```c
/* conf_thread.c:4507 @ bf14c2e2c */
pj_assert(listener->transmitter_cnt == 1 && listener->last_timestamp.u64 != timestamp->u64);
```

`timestamp` is the frame timestamp handed to the bridge master port's `get_frame()`. Under
pjsua-lib that is the sound port's `pjmedia_clock` (`sound_port.c` `clock_callback`, the
`PJMEDIA_SND_PORT_USE_SW_CLOCK` path that `PJSUA_DEFAULT_SND_USE_SW_CLOCK` enables) or the
`pjmedia_master_port` clock of the null device. Every sound-device (re)open creates a new clock,
and `pjmedia_clock_create2()` starts it at 0 (`clock_thread.c:246`, `clock->timestamp.u64 = 0`).
`conf_port->last_timestamp`, however, is set to `(pj_uint64_t)-1` once at port creation
(`conf_thread.c:880`) and otherwise written only by `mix_and_transmit()` — it survives the
reopen. A listener that is not mixed for a few ticks after the reopen (its transmitter returned
`PJMEDIA_FRAME_TYPE_NONE`: jitter-buffer prefetch, silence, DTX) is mixed again exactly when the
new clock reaches its stored value, and the assert fires. With `PJ_DEBUG` 1 that is an `abort()`
on the clock thread; a TestFlight build of a pjsua-based iOS app died this way within ten seconds
of answering a call.

Only the parallel bridge carries this invariant. `conference.c` clears the mix buffer of every
listener that has a transmitter at the top of each tick (`conference.c:3304`) and never compares
timestamps.

## Environment

- pjproject master `bf14c2e2c` (the files involved are identical at `ce5403cf4`, where the
  reproductions below were built).
- iOS device build (arm64), pjsua-lib, `PJMEDIA_CONF_BACKEND` left at default →
  `PJMEDIA_CONF_PARALLEL_BRIDGE_BACKEND`; `PJMEDIA_CONF_THREADS` default 1 on `TARGET_OS_IPHONE`
  → `pjmedia_conf_param.worker_threads == 0`, `conf->is_parallel == PJ_FALSE`.
- `pjsua_media_config.snd_use_sw_clock` default (`PJ_TRUE`); `clock_rate` and `snd_clock_rate`
  48000, `audio_frame_ptime` 20 → `samples_per_frame` 960.
- The application starts on `pjsua_set_null_snd_dev()` and switches to the real device with
  `pjsua_set_snd_dev()` when CallKit activates the audio session, back to null on deactivation.

## Observed crash (symbolicated, app frames omitted)

```text
Exception Type:  EXC_CRASH (SIGABRT)
Thread N Crashed (pjmedia clock thread):
0  libsystem_kernel.dylib   __pthread_kill
1  libsystem_pthread.dylib  pthread_kill
2  libsystem_c.dylib        abort
3  libsystem_c.dylib        __assert_rtn
4  app                      perform_get_frame.cold.8 + 40      (conf_thread.c, mix_and_transmit inlined)
5  app                      perform_get_frame + 6060
6  app                      get_frame + 136                     (conf_thread.c)
7  app                      clock_callback + 100                (sound_port.c — SW clock, real device)
8  app                      clock_thread + 312                  (clock_thread.c)
9  app                      thread_main + 152
```

The `cold.8` stub resolves (Mach-O relocations in the object) to `__func__.mix_and_transmit`,
`"conf_thread.c"` and the string
`listener->transmitter_cnt == 1 && listener->last_timestamp.u64 != timestamp->u64`, line 4507.
`clock_callback + 100` is the return address of `pjmedia_port_get_frame(port, &frame)` in
`sound_port.c`'s `clock_callback` (the `master_port.c` callback has no call returning at +100),
so the real device was open and its software clock was driving the bridge. On another thread
the same sound port's `rec_cb` was in `pjmedia_delay_buf_put(cap_dbuf)` → `shrink_buffer`,
consistent with the clock thread having stopped draining the capture delay buffer.

## Why the collision is reachable

1. `pjsua_set_null_snd_dev()` → `set_null_snd_dev2()` (legacy path, `avoid_clock_gap` false)
   closes whatever is open and creates a new `pjmedia_master_port` + `pjmedia_clock` — also when
   the null device is already active.
2. `pjsua_set_snd_dev()` → `open_snd_dev()` creates a new `pjmedia_snd_port`, whose
   `PJMEDIA_SND_PORT_USE_SW_CLOCK` clock is new as well. (Re-requesting a device that is already
   open is a no-op: `set_snd_dev2()` returns early with "No changes in capture and playback
   devices" — verified.)
3. The bridge's ports, including slot 0, are not recreated by either; `last_timestamp` keeps the
   value of the last tick on which the listener was mixed.
4. The next clock counts 0, 960, 1920, …; if the listener is skipped for *k* ticks (transmitter
   returned `PJMEDIA_FRAME_TYPE_NONE`) and is mixed again when `timestamp == last_timestamp`,
   the single-transmitter branch asserts.

## Deterministic reproduction (pjmedia only)

`pjmedia_conf_create2()` with `worker_threads = 0` and `PJMEDIA_CONF_NO_DEVICE`; one custom
transmitter port connected to slot 0; the master port's `get_frame()` is called directly with
explicit timestamps, exactly as `sound_port.c`'s `clock_callback` does. Full program:
`conf_restart_repro.c` (attached). Ticks:

```text
tick ts=0      tx=audio connect applied after tick   -> frame NONE   (op queue drains after the tick)
tick ts=960    tx=audio first mixed tick             -> frame AUDIO  last_timestamp = 960
tick ts=1920   tx=audio                              -> frame AUDIO  last_timestamp = 1920
--- "device reopened": new pjmedia_clock, timestamps restart at 0 ---
tick ts=0      tx=none  (prefetch)                   -> frame NONE
tick ts=960    tx=none  (prefetch)                   -> frame NONE
tick ts=1920   tx=audio ts == last_timestamp         ->
Assertion failed: (listener->transmitter_cnt == 1 && listener->last_timestamp.u64 != timestamp->u64),
function mix_and_transmit, file conf_thread.c, line 4507.    [exit 134]
```

Controls: the same six ticks with monotonic timestamps (2880, 3840, 4800 after the gap) do not
assert; a restart where the transmitter is audible on the very first restarted tick does not
assert either (0 ≠ 1920, and `last_timestamp` then tracks the new clock). The collision needs
both the epoch restart and the skipped ticks.

Built with `PJ_DEBUG 0`, the same tick logs one line at level 1 —
`Assert failed: listener->transmitter_cnt == 1 && listener->last_timestamp.u64 != timestamp->u64`
— the returned frame carries the transmitter's samples (960/960 correct), and the following ticks
are clean: the branch below the assert rewrites `last_timestamp` unconditionally, so the condition
clears itself. In this branch the assert guards nothing the code depends on.

## pjsua-level evidence that the epoch restarts

`pjsua_clock_restart.c` (attached) connects slot 0 to a custom listener port and prints the
timestamps `write_port()` hands to its `put_frame()` (`frame.timestamp = timestamp * port_rate /
conf_rate`, i.e. the bridge timestamp). macOS, default output device, speaker-only:

```text
--- null A ---                     ts=960, 1920, 2880 …           (step 960: 48 kHz × 20 ms)
--- null B (set_null again) ---    RESTART: prev ts=18240 now ts=0
--- real dev C (SW clock) ---      RESTART: prev ts=18240 now ts=11466   (step 882: device at 44.1 kHz)
--- real dev D (same device) ---   no restart — set_snd_dev2: "No changes in capture and playback devices"
--- null E ---                     RESTART: prev ts=64386 now ts=0
frames seen by listener: 120, timestamp restarts: 3
```

## Impact

- `PJ_DEBUG` 1 (the default when `NDEBUG` is not defined): `abort()` on the clock thread, i.e. a
  crash of the application mid-call.
- `PJ_DEBUG` 0: one log line; the single-transmitter branch recovers by itself (verified above).
  Reading the neighbouring code, the same stale-equal `last_timestamp` would make the
  `transmitter_cnt > 1` branch take the "sum" path onto the previous tick's `mix_buf` for one
  frame (`conf_thread.c:4443`), and would make `write_port()` treat the stale `mix_buf` as this
  tick's data instead of sending a heartbeat `NONE` frame (`conf_thread.c:3555`) — one-frame
  glitches. Not reproduced; stated from the code.

## Suggestions

1. Make the bridge's "already mixed this tick" bookkeeping independent of the master port's
   timestamp epoch — e.g. a bridge-owned tick counter incremented in `get_frame()` and compared
   per listener, or reset every port's `last_timestamp` to `-1` when the master port's incoming
   timestamp goes backwards (a new clock).
2. Independently of (1), the `pj_assert` in the single-transmitter branch could become a logged
   check: the code below it does not rely on the invariant, and an `abort()` on the sound/clock
   thread is the worst possible outcome for a production endpoint.

## Workaround in use

`#define PJMEDIA_CONF_BACKEND PJMEDIA_CONF_SERIAL_BRIDGE_BACKEND` (and `PJ_DEBUG 0`).

## Attachments

- `conf_restart_repro.c` — deterministic pjmedia-level reproduction (modes `restart`,
  `monotonic`, `restart-immediate`).
- `pjsua_clock_restart.c` — pjsua-level timestamp-restart evidence.

(Both live in `../conf-assert-repro/` next to this repository until the report is filed.)
