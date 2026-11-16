# TLS on Apple platforms in PJSIP

What the two Apple TLS backends actually do with certificates, how they differ from each
other and from OpenSSL, and what that means for anyone wiring up TLS or certificate
pinning on top of the `PJSIP.xcframework` this package ships.

Written up after tracing the backends against pjproject master (`256f22d8d`, Aug 2026)
and testing both on macOS 26 and the iOS 26 Simulator. Upstream issue/PR numbers are
linked at the end.

## The two backends

PJSIP has **two** separate Apple TLS backends. They are not versions of each other and
neither is a rename of the other.

| | `PJ_SSL_SOCK_IMP_DARWIN` = 3 | `PJ_SSL_SOCK_IMP_APPLE` = 4 |
|---|---|---|
| source | `pjlib/src/pj/ssl_sock_darwin.c` | `pjlib/src/pj/ssl_sock_apple.m` |
| Apple API | Secure Transport (`SSLCreateContext`) | Network.framework (`nw_*`) |
| Apple status | deprecated in macOS 10.15 / iOS 13 | current |
| added | pjproject #2185 | pjproject #2482 |
| socket layer | `pj_activesock` + ioqueue | its own (`SSL_SOCK_IMP_USE_OWN_NETWORK`) |

**We ship `PJ_SSL_SOCK_IMP_APPLE`**, set in `scripts/config_site-ios.h`. That is the
right choice and should not be changed casually: the Darwin/Secure Transport backend sits
on an API Apple deprecated in 2019, and it carries live defects (below).

### "darwin" means the opposite in pjmedia — do not carry the inference across

The table above teaches a rule that is true here and false one directory away: in pjlib's TLS
code `darwin` is the legacy backend and `apple` is the modern one. In pjmedia's video device
layer the same word marks the **current** implementation.

| file | wraps | status |
|---|---|---|
| `pjlib/src/pj/ssl_sock_darwin.c` | Secure Transport | deprecated since 2019 |
| `pjmedia/src/pjmedia-videodev/darwin_dev.m` | **AVFoundation** | current, and the only live capture path |
| `pjmedia/src/pjmedia-videodev/qt_dev.m` | QTKit | the legacy one — `PJMEDIA_VIDEO_DEV_HAS_QT` defaults to `0` |

So pjmedia has the same legacy/modern split, with the naming inverted: `qt` is old and `darwin`
is new. Anyone arriving from the TLS work — where "darwin" reliably means "the deprecated one" —
will read `darwin_dev.m` as legacy and be wrong about the file that captures every frame we send.

`darwin_dev.m` is also the odd one out in its own directory, where the convention is to name a
backend after the API it wraps rather than after the OS: `coreaudio_dev.m`, `dshow_dev.c`,
`v4l2_dev.c`, `metal_dev.m`, `opengl_dev.c`, `qt_dev.m`. By that rule it would be `avf_dev.m`,
the exact analogue of `coreaudio_dev.m` in the sibling audio directory.

We are not proposing that rename upstream. `PJMEDIA_VIDEO_DEV_HAS_DARWIN` is a user-visible
build knob, so renaming it would hand anyone who sets it a silent build with no camera rather
than an error — a poor trade for a naming improvement. If it is ever worth raising it belongs in
a major version and has to be additive: introduce `PJMEDIA_VIDEO_DEV_HAS_AVF`, keep the old macro
working as an alias, rename the file, and drop the alias a release later.

## Selecting a backend

`./configure` **cannot select either backend** on a current SDK. This is worth knowing
because it makes the build look like it succeeded while quietly producing no TLS at all.

- `--enable-darwin-ssl` is a no-op. `aconfigure.ac`'s `AC_ARG_ENABLE(darwin-ssl, …)` puts
  its probe in the *action-if-not-given* arm, so passing the flag skips the probe, and the
  action-if-given arm only handles `no`. No probe, no define, no output. Only
  `--disable-darwin-ssl` is documented, and only that spelling does anything.
- Without the flag, the probe runs and fails: it compiles with `-Werror` and calls
  `SSLReHandshake`, deprecated since macOS 10.15. You get
  `Checking if Darwin SSL is available... no`.
- `PJ_SSL_SOCK_IMP_APPLE` appears nowhere in `aconfigure.ac`. It has no flag at all.

So TLS is selected **only** by `config_site.h`, which is what our `build.sh` does. The
cascade when it is not set is silent: `PJ_HAS_SSL_SOCK` undefined →
`PJSIP_HAS_TLS_TRANSPORT` (which defaults to `PJ_HAS_SSL_SOCK`) undefined →
`sip_transport_tls.c` compiles to nothing → the TLS transport simply does not exist, and
you find out at runtime when `pjsua_transport_create(PJSIP_TRANSPORT_TLS, …)` fails.

`-framework Security` is only added inside the probe's success branch, and
`-framework Network` is never added by the build system at all — so a `config_site.h`
build needs those linker flags supplied by hand. Ours are.

> The `--enable-darwin-ssl` in `Codec-Coverage.md`'s recorded configure flags is therefore
> decorative; it is not what selects our TLS. `build.sh` already carries a comment saying
> so.

### This is now a build check, not just this paragraph

`scripts/verify-xcframework.sh` asserts the backend from the artefact's symbol table, so a
`config_site.h` that stops selecting it fails CI instead of failing in an app. The three
backends are distinguishable by who they call, and the check is exactly that:

| backend | undefined symbols it leaves in `libpjproject.a` |
|---|---|
| `PJ_SSL_SOCK_IMP_APPLE` (ours) | `_nw_*` **and** `_sec_protocol_*` |
| `PJ_SSL_SOCK_IMP_DARWIN` | Secure Transport: `_SSLCreateContext`, `_SSLHandshake`, … (`^_SSL[A-Z]`) |
| OpenSSL | `_SSL_CTX_new`, `_OPENSSL_init_ssl` |

Note that `_Sec*` on its own proves nothing — **both** Apple backends call
Security.framework to import certificates, which is why the check pairs `_nw_*` with
`_sec_protocol_*` and separately requires zero `^_SSL[A-Z]`. Measured on the 2.17.0
(`288de6142`) artefact: 33 `_nw_*`, 12 `_sec_protocol_*`, 0 Secure Transport, 0 OpenSSL,
identical across both slices.

## The Apple backend requires the select ioqueue

Not documented anywhere upstream, and easy to get wrong: **`PJ_SSL_SOCK_IMP_APPLE` only
works with `PJ_IOQUEUE_IMP_SELECT`.**

`ssl_sock_apple.m` drives every asynchronous callback — connection state, accepted
connections, reads, handshake completion — from `ssl_network_event_poll()`. That function
is defined in `ssl_sock_apple.m:276` and called from exactly one place in the tree,
`ioqueue_select.c:975`, under `#if PJ_SSL_SOCK_IMP == PJ_SSL_SOCK_IMP_APPLE`. Neither
`ioqueue_kqueue.c` nor `ioqueue_epoll.c` mentions it.

So a build combining the Apple TLS backend with the kqueue ioqueue **compiles, links, and
then never completes a single TLS connection** — the Network.framework event queue is
never drained. There is no runtime error; connections simply hang.

We are safe today because our `config_site.h` does not override `PJ_IOQUEUE_IMP`, and
`config.h:752` defaults it to `PJ_IOQUEUE_IMP_SELECT`. **Do not "optimise" that to kqueue.**
If anyone is tempted, the whole reason is above. Upstream has been asked for a compile-time
`#error` on the combination, and **got it — pjproject#5230, merged.** It is in the artefact
since `0.3.0`, so a kqueue override now fails to compile instead of hanging at run time.

## Where the certificate gets loaded: eager vs lazy

This is the difference that drove the upstream work, and it matters because it decides
*when* you learn a certificate is wrong.

`pj_ssl_cert_load_from_files2()` does **no I/O**. It is `pj_strdup` of the paths and
nothing more. Whatever validates a certificate happens later, in the backend.

| backend | when the server identity is loaded | consequence |
|---|---|---|
| **Apple** (Network.framework) | **eagerly**, once, at listener start — `network_start_accept()` → `network_create_params()` → `create_identity_from_cert()`, before `nw_listener_create()` | a bad certificate fails `pj_ssl_sock_start_accept()` itself. Accepted connections inherit the listener's `nw_parameters`, and the child's `ssl_create()` is a no-op, so the identity is loaded exactly once for the listener's lifetime |
| **Darwin** (Secure Transport) | **lazily**, per connection — `set_cert()` is reachable only from `ssl_create()`, which never runs on the listener | the listener reports ready with a missing or unparsable certificate, and every inbound connection fails its handshake instead |
| **OpenSSL** | eagerly since pjproject #5210 (Aug 2026); lazily before that | `SSL_CTX` is built and cached on the listener at start |

Two practical consequences of the Apple backend being eager and pinning:

1. **A bad certificate fails transport creation**, not the first call. You get the error
   from `pjsua_transport_create()`, which is where you want it.
2. **Replacing the certificate file while the listener is up has no effect.** The identity
   is captured in the listener's TLS options at start. To pick up a rotated certificate
   you must restart the listener — `pjsip_tls_transport_restart()` /
   `pjsua_transport_lis_restart()`. pjsua's own `restart_listener()` in `pjsua_core.c` is
   the model: call restart, and on failure reschedule via `pjsua_schedule_timer2()`.

The Darwin backend behaves the opposite way on both counts — it never validates at start,
but it *does* pick up a replaced file on the next connection. That is accident, not
design, and it is the subject of the upstream discussion linked below.

## Certificate material: iOS and macOS are not the same

The single most surprising finding, and the one to remember before writing any test:
**the same `.p12` that works on iOS fails on macOS.**

| | iOS | macOS |
|---|---|---|
| import call | `SecPKCS12Import()` | `SecItemImport()`, trying PKCS#12 → PEM sequence → DER |
| result shape | array of `CFDictionary`, identity under `kSecImportItemIdentity` | typically a bare `SecCertificateRef` |
| private key source | **from the `.p12` itself** — self-contained | looked up **in the keychain** via `SecIdentityCreateWithCertificate()` |
| a `.p12` alone is enough | yes | no — fails `errSecItemNotFound` |

Both backends log `"Ignoring supplied private key. Private key must be placed in the
keychain instead."` if you set `privkey_file`/`privkey_buf`. **There is no separate
private-key file on Apple platforms.** The key must arrive inside the PKCS#12 bundle, or
already be in the keychain. This also means the OpenSSL-style "certificate and key do not
match" failure is not representable here — a `SecIdentity` is a matched pair by
construction.

For tests and CI: use a password-protected `.p12` and run on iOS (or the Simulator) if you
want the positive path to work without touching a keychain. On macOS you must import the
identity into a keychain in the search list first, which is intrusive on a developer
machine.

## Trust evaluation and certificate pinning

Both Apple backends implement pinning, and it is better supported than the docs suggest.
The hook is the CA you supply, not a custom callback:

```
pj_ssl_cert_t.CA_file  /  CA_buf        →   pjsip_tls_setting.ca_list_file / ca_buf
```

When a CA is configured, `verify_cert()` does:

```c
SecTrustSetAnchorCertificates(trust, ca_array);
SecTrustSetAnchorCertificatesOnly(trust, true);   /* system roots excluded */
SecTrustEvaluateWithError(trust, &error);
```

`SecTrustSetAnchorCertificatesOnly(true)` is the important line: it removes the system
trust store from consideration entirely, so the peer must chain to *your* anchor. That is
real pinning, not merely "additionally trust this CA".

Constraints to design around:

- **The CA must be DER, not PEM.** It goes through
  `SecCertificateCreateWithData()`, which takes a single DER-encoded certificate. The
  backend logs `"Failed creating certificate from CA file/buffer. It has to be in DER
  format."` when it is not.
- **One anchor, not a bundle.** The code builds a one-element anchor array from a single
  certificate. Pinning to a chain or rotating between two anchors is not expressible
  through this path as written.
- **Before `0.3.0`, keep the CA file under 8 KB.** Through `0.2.1`, `create_data_from_file()`
  read with a single `CFReadStreamRead()` into a fixed `UInt8[8192]` and treated whatever it
  got as the whole file. Larger files were silently truncated and then failed as "unparsable",
  on the CA path as well as the certificate path. pjproject#5222 reads the whole file; it is
  in the artefact since `0.3.0`.
- Leaf-key pinning (pin the public key rather than the anchor) is **not** available
  through this API. It would need a custom verify block, which the Apple backend uses
  internally but does not expose through `pj_ssl_sock_param`.

### Certificate parsing: hardened since 0.3.0, still untrusted input

This matters specifically for pinning, because pinning means deliberately accepting
connections from peers whose certificates you have not vetted, and then inspecting them.
`get_cert_info()` runs on **every completed handshake**, against the **peer's**
certificate. **Through 0.2.1** it had four unguarded paths, all found in review of
pjproject#5224. **pjproject#5282 fixed all four and the leak below, and it is in the artefact
since 0.3.0**: on master `bd69054a6` the `SecCertificateCopyValues()` result is NULL-checked
before use, the subject comes from its OID with type guards instead of
`SecCertificateCopySubjectSummary()`, the SAN array is NULL-, type- and count-checked, an
over-length serial is flagged as truncated rather than over-read, and refreshed cert info is
allocated from a pool that is reset, so renegotiations no longer leak. The table is what
0.2.1 shipped:

| what | trigger | effect |
|---|---|---|
| `SecCertificateCopyValues()` result dereferenced before its NULL check | unparsable peer certificate | crash |
| `SecCertificateCopySubjectSummary()` result unchecked into `CFStringGetCString()` | **SAN-only leaf with an empty subject** | crash |
| SAN out-param may be NULL while its dictionary is not; `CFArrayGetCount(NULL)` | malformed SAN extension | crash |
| serial compared with an unclamped length against `pj_uint8_t serial_no[20]` | serial longer than 20 octets | over-read; the "has the cert changed" test decides on adjacent struct bytes |

Two of those are worth dwelling on. **SAN-only certificates are normal now** — modern
issuers routinely emit leaves with an empty subject and everything in the SAN — so that
one is not an exotic edge case. And an over-length serial is emitted by some
non-conforming CAs.

Through 0.2.1 there was also a per-renegotiation leak: `get_cert_info()`'s "nothing changed"
early return freed one CoreFoundation object and not the other two, so a long-lived TLS
connection leaked a `CFData` (and on macOS a `CFString`) on every renegotiation.

Practical consequence, unchanged by the fixes: treat the peer certificate as
attacker-controlled input. The known crash paths are closed, but the parser is hand-written
CoreFoundation walking, and this repository has no fuzzing of it. If we ever expose pinning to
a counterparty we do not control, prefer not reading `pj_ssl_cert_info` for peers we do not
trust.

### Certificate files are read into memory with a hand-rolled loop

Only the Apple backends read certificate files themselves; OpenSSL, GnuTLS and mbedTLS all
hand the path to the TLS library. The Apple helper originally truncated at 8 KB
(pjproject#5222 fixes that; in the artefact since 0.3.0), and the fix has to be careful not to become unbounded — a
`cert_file` pointing at a FIFO or `/dev/zero` would otherwise hang or exhaust memory on
the `pj_ssl_sock_start_accept()` path. Keep certificate paths under our own control and
pointing at regular files.

## Known defects, upstream status

Everything below was found while tracing this. **Statuses re-checked against the pjsip/pjproject
API on 11 Oct 2026.** Everything marked merged is in the artefact since `0.3.0` (master
`bd69054a6`).

| what | affects | upstream status |
|---|---|---|
| Over-release of the imported identity → **segfault on iOS on any valid `.p12`** | Darwin only; fixed in Apple 2023, never backported | **merged** (#5220) |
| Listener reports ready with an unloadable certificate | Darwin only; Apple was already eager | **merged** (#5216, and #5210 for OpenSSL) |
| `create_data_from_file()` truncates at 8 KB | **both** backends | **merged** (#5222) |
| Apple TLS backends unbuildable via CMake (`FATAL_ERROR "TODO"`) | both | **merged** (#5223) |
| `apple` + non-select ioqueue builds but never connects | Apple | **merged** (#5230) — now a compile-time rejection |
| `--enable-darwin-ssl` no-op; neither backend selectable from configure | build system | fix **merged** (#5221); issue #5217 still open as the register |
| Certificate code duplicated between the two backends, copies diverged | both | dedup **merged** (#5224, #5226); issue #5215 closed 2026-09-09 |
| Unguarded paths in `get_cert_info()` + the per-renegotiation leak | both | **merged** (#5282, for #5232 §1–3) |
| TLS version bounds discarded by the Darwin backend | Darwin | **merged** (#5234, #5232 §4) |
| `restart2()` returns `PJ_SUCCESS` without restarting a downed listener | TCP and TLS transports | **merged** (#5233, #5232 §5) |
| `restart2()` has no `cert_direct` branch although listener start does | TLS transport, both backends | #5233's single credential loader covers `cert_direct` too; not separately confirmed against #5232 §6 |
| iOS import failures logged as `SecItemImport`, but iOS uses `SecPKCS12Import` | Apple | **open** (#5232 §7) |

The last three came out of building runtime TLS tests against the shipped backend rather than
from reading it — see `swift-pjsua/docs/Tech-Debt.md` TD-19 and TD-22.

> ### Merged upstream is shipped here since 0.3.0
>
> Through `0.2.1` the binary was PJSIP 2.17.0 (`288de6142`), which predates every merge in the
> table, so "merged" meant "fixed for whoever builds master", not "fixed for us". `0.3.0` is built
> from master `bd69054a6` and carries all of them. The 8 KB truncation is gone with it, and
> `swift-pjsua`'s oversized-PKCS#12 test, which asserted the failure as a detector, now asserts
> that the file loads.

**Bottom line for us:** we ship the Apple/Network.framework backend — the one without the crash,
and the one that already validated eagerly. Since `0.3.0` the 8 KB truncation and the
`get_cert_info()` gaps are fixed in the artefact, and a non-select ioqueue no longer compiles. What
is left upstream is a misleading log label (#5232 §7) and an unlocked credential swap during a
listener restart, which #5233 names as a known follow-up.

## The lesson worth keeping

The most expensive defect in this list — a guaranteed iOS segfault on any valid PKCS#12 —
survived three years for one reason: **the fix was applied to one of two byte-identical
copies of the same function, and nobody diffed the other.**

Then it happened again. While fixing that very drift, we added two more fixes to
`ssl_sock_darwin.c` and did not mirror them into `ssl_sock_apple.m` — caught only because
a reviewer diffed the copies again.

So when working anywhere in `ssl_sock_darwin.c` or `ssl_sock_apple.m`, until pjproject#5224
lands: **any change to one is a change to both.** Diff the pair before assuming otherwise.
That is the entire argument for the deduplication PR, and it is worth more than the ~360
lines it removes.

## ClientHello size and the post-quantum key share

Since iOS 26 / macOS 26 the platform TLS stack advertises the hybrid post-quantum group
**`X25519MLKEM768`** in every TLS 1.3 ClientHello and sends a key share for it. Apple's
advisory:

> Devices … may fail to connect to some legacy servers due to an incorrect TLS
> implementation that fails to read large `ClientHello` messages.
> — <https://support.apple.com/en-us/122756>

That share alone is 1216 bytes (a 1184-byte ML-KEM-768 encapsulation key,
[FIPS 203](https://csrc.nist.gov/pubs/fips/203/final), plus a 32-byte X25519 share), so the
hello is about 1.5 KB. An Ethernet path carries 1448 bytes per TCP segment once timestamps
are on, so this hello is **split across two segments on every path**, not only on tunnelled
ones; a smaller path MSS moves the split point and nothing else. A TLS 1.2-only hello from
the same stack is about 200 bytes.

Splitting is legal — TCP is a stream and the record carries its length — but two
receiver-side defect classes are known to break on it:

1. **Read-once TLS stacks.** A server or front end that issues one `read()` and assumes it
   holds the whole hello. Chromium's rollout notes: *"the call to read() on the TCP socket
   will not return the entire ClientHello in a single call. Not all implementations are
   prepared for this"*.
2. **Middleboxes** that parse the hello from the first data segment and drop or reset a
   flow they cannot fully inspect (the breakage reported when Chrome enabled Kyber in 2024).

Before blaming either, look at the packets. A handshake that hangs is the symptom of
several unrelated things, this backend reports all of them identically (next section), and
the one field case examined so far turned out to be a SYN proxy, with a 517-byte hello (the
section after that).

**What controls the hello from pjsip.** Only the version range. `param.proto` becomes
`sec_protocol_options_set_min/max_tls_protocol_version` (`ssl_sock_apple.m:867-922`);
without TLS 1.3 in the range there is no `key_share` at all. Two defaults exist and they
differ:

- Through pjsip's TLS transport the range is explicit whenever the setting was initialised
  the usual way. `pjsip_tls_setting_default()` sets `PJSIP_SSL_DEFAULT_PROTO` — TLS 1.0, 1.1
  and 1.2 — so a transport created from `pjsua_transport_config_default()` asks the OS for
  min 1.0 / max 1.2 and never offers TLS 1.3 unless the application adds
  `PJ_SSL_SOCK_PROTO_TLS1_3` to `tls_setting.proto` (a bit mask: adding it widens the
  maximum, it does not select 1.3 alone).
  (`tls_setting.method` is ignored whenever `proto` is non-zero — `ssl_get_proto()` in
  `sip_transport_tls.c` — so setting only `method` changes nothing.)
- The backend's own default, TLS 1.2 + 1.3, applies to `PJ_SSL_SOCK_PROTO_DEFAULT`
  (`ssl_sock_apple.m:871-874`), which reaches it from code using `pj_ssl_sock` directly, or
  from a zero-filled `pjsip_tls_setting` whose `method` is unset.

This is the Apple backend. The Darwin backend discarding version bounds (#5234 in the
defect table above) is a different matter.

No finer knob exists. `param.curves` and `param.sigalgs` are never read by this backend,
`param.ciphers` only appends ciphersuites, and socket options are ignored outright. The
functions that would keep TLS 1.3 while dropping the post-quantum share —
`sec_protocol_options_append_tls_key_exchange_group` and
`sec_protocol_options_set_pqtls_mode` — are exported by `Security.framework` but declared in
no public header (checked against `Security.tbd` and `SecProtocolOptions.h` of the
iPhoneOS 27.2 SDK), so they are private API and not shippable.

Refs: Apple <https://support.apple.com/en-us/122756> ·
<https://support.apple.com/guide/security/tls-security-sec100a75d12/web> ·
Chromium intent <https://groups.google.com/a/chromium.org/g/blink-dev/c/xb4JCKhED3k> ·
<https://tldr.fail> (a vendor-facing write-up of the read-once defect).

## Failures before the certificate all look like a handshake timeout

For an outgoing connection this backend tells the application nothing until the server's
certificate has arrived:

- The `nw_connection` state handler posts the completion event only for
  `nw_connection_state_ready`, or for an error that arrives while
  `ssl_state == SSL_STATE_HANDSHAKING` (`ssl_sock_apple.m:1095-1161`).
- `ssl_state` becomes `SSL_STATE_HANDSHAKING` in `ssock_on_connect_complete()`
  (`ssl_sock_imp_common.c:1360`), and this backend reaches that function only from the
  `sec_protocol` verify block (`ssl_sock_apple.m:967-990`) — that is, once there is a peer
  certificate to verify.
- An earlier error is passed to BSD `warn()`, which writes to stderr, not to the pjlib log.

So a refused or unreachable TCP connect, a reset, a connection that is up but passes no
data, and a lost ClientHello or ServerHello all surface the same way: `PJ_ETIMEDOUT` when
`pj_ssl_sock_param.timeout` expires, and **never** if that timeout is zero. The
socket-based backends report the OS error from `connect()` at once.

The log does carry one bit. `Handshake failed on <local> in connecting to <remote>`
(`ssl_sock_imp_common.c:410-426`) prints the local address, and for a client socket bound to
the wildcard address — the normal pjsip case — it is filled in only by
`ssock_on_connect_complete()`:

| Logged local address | Meaning |
|---|---|
| `(unknown)` | the verify block never ran: no server certificate arrived (TCP or early-TLS failure of any kind) |
| an address with an ephemeral port | the certificate arrived; the failure came later |

Do not read a run of `SSL timeout after N s` lines on iOS as "the server was slow to answer
the hello". It says only that the handshake was still unfinished after N seconds — the
`(unknown)` vs ephemeral local address above is what says whether a certificate had arrived,
and a `tcpdump`, or a plain TCP probe next to the TLS connection, is what tells the causes
apart.

Source reading confirmed by DeepWiki against upstream `d78f0ddc`:
<https://deepwiki.com/search/three-questions-about-the-appl_71f63161-eea2-46a8-bbba-6e7363d3cbfd?mode=deep>.
Not reported upstream yet.

## A zero-window SYN-ACK from a SYN proxy

One field case of "the TLS handshake hangs" turned out to be below TLS. A SYN proxy in front
of the server answered some SYNs itself:

```
C > S  [S]   seq x                 <mss 1460, wscale 5, TS val a ecr 0, sackOK>
S > C  [S.]  seq y ack x+1  win 0     <mss 1460, wscale 5, sackOK, TS val 11700 ecr 0>
C > S  [.]   ack y+1
S > C  [S.]  seq y ack x+1  win 2036  <mss 1380, sackOK, TS val 11700 ecr a', wscale 7>
C > S  [.]   ack y+1
             … nothing for 60 s, then one byte every 60 s …
```

The first SYN-ACK is the proxy's: window 0, the client's own MSS and window scale repeated
back, `TSecr 0`. The second carries the real server's options and is meant to open the
window. Apple's TCP answers a SYN in an established connection with a challenge ACK and
drops it before window processing (xnu `tcp_input.c`, `case TCPS_ESTABLISHED`; RFC 5961 §4.2
«Mitigation», <https://www.rfc-editor.org/rfc/rfc5961#section-4.2>), so the send window
stays 0 and the ClientHello is never sent. The connection is up; nothing moves.

What the application sees: `SSL timeout after N s` and
`Handshake failed on (unknown) …` — the same as for every other failure before the
certificate.

Measured with a packet-level emulator replaying that exchange against macOS 27.2 (plain
sockets and `NWConnection`, with and without TLS):

- The first data byte is a zero-window probe after **60 s** or **5 s**. The 60 s come from
  `TSecr 0`: with the connection's random timestamp offset subtracted it is no longer zero,
  the stack takes "now − TSecr" as a round-trip sample capped at 60 s, and the persist timer
  inherits it; which of the two a connection gets depends on the sign of its own first
  TSval. With TSval echoed correctly (RFC 7323 §3.2 «Timestamps Option»,
  <https://www.rfc-editor.org/rfc/rfc7323#section-3.2>) it is always 5 s. In the iOS captures
  it was 60 s in all six connections that were observed long enough.
- A plain ACK with a non-zero window instead of the second SYN-ACK: data flows at once.
- TCP keepalive with a 1 s idle time: if the peer answers the keepalive with an ACK, the
  window opens and the data goes out about 1.2 s after connect; if it stays silent, the
  connection is dropped with `ETIMEDOUT` after about 4 s. What a real proxy does with a
  keepalive was not observed.
- `nw_tcp_options_set_persist_timeout` does not help: the limit is checked only when the
  persist timer fires.

This backend cannot use any of that: it applies no TCP options to its `nw_parameters`
(`network_create_params()`: "Currently we ignore QoS and socket options").

How to recognise it:

- In a capture: `tcpdump -nn -r FILE 'tcp[tcpflags] & (tcp-syn|tcp-ack) == (tcp-syn|tcp-ack) and tcp[14:2] == 0'`
  lists SYN-ACKs with window 0. A healthy server never sends one.
- From the application, without a capture: connect a plain BSD socket to the same address
  and read `TCP_CONNECTION_INFO` straight after `connect()`. An intercepted connection shows
  `tcpi_snd_wnd == 0`, `tcpi_snd_wscale == tcpi_rcv_wscale` (the mirrored scale) and, for
  about half of the connections, `tcpi_srtt` of 60000 ms.

