# TLS on Apple platforms in PJSIP

What the two Apple TLS backends actually do with certificates, how they differ from each
other and from OpenSSL, and what that means for anyone wiring up TLS or certificate
pinning on top of the committed `PJSIP.xcframework`.

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
`#error` on the combination (pjproject#5223); until that lands, this doc is the guard.

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
- **Keep the CA file under 8 KB.** `create_data_from_file()` reads with a single
  `CFReadStreamRead()` into a fixed `UInt8[8192]` and treats whatever it gets as the whole
  file. Larger files are silently truncated and then fail as "unparsable". This affects
  the CA path as well as the certificate path. See the upstream issue below.
- Leaf-key pinning (pin the public key rather than the anchor) is **not** available
  through this API. It would need a custom verify block, which the Apple backend uses
  internally but does not expose through `pj_ssl_sock_param`.

### Certificate parsing is not hardened — assume peer certs can crash it

This matters specifically for pinning, because pinning means deliberately accepting
connections from peers whose certificates you have not vetted, and then inspecting them.
`get_cert_info()` runs on **every completed handshake**, against the **peer's**
certificate, and as of pjproject master it has four unguarded paths (all found in review
of pjproject#5224, none fixed at time of writing):

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

Practical consequence: treat the peer certificate as attacker-controlled input that the
library does not fully validate before parsing. If we ever expose pinning to a
counterparty we do not control, we want these fixed upstream first, or we want to avoid
reading `pj_ssl_cert_info` for peers we do not trust.

There is also a per-renegotiation leak: `get_cert_info()`'s "nothing changed" early return
frees one CoreFoundation object and not the other two, so a long-lived TLS connection
leaks a `CFData` (and on macOS a `CFString`) on every renegotiation.

### Certificate files are read into memory with a hand-rolled loop

Only the Apple backends read certificate files themselves; OpenSSL, GnuTLS and mbedTLS all
hand the path to the TLS library. The Apple helper originally truncated at 8 KB
(pjproject#5222 fixes that), and the fix has to be careful not to become unbounded — a
`cert_file` pointing at a FIFO or `/dev/zero` would otherwise hang or exhaust memory on
the `pj_ssl_sock_start_accept()` path. Keep certificate paths under our own control and
pointing at regular files.

## Known defects, upstream status

Everything below was found while tracing this. Status as of 31 Aug 2026.

| what | affects | status |
|---|---|---|
| Over-release of the imported identity → **segfault on iOS on any valid `.p12`** | Darwin only; fixed in Apple 2023, never backported | **merged** (pjproject#5220) |
| Listener reports ready with an unloadable certificate | Darwin only; Apple was already eager | **merged** (pjproject#5216) |
| `create_data_from_file()` truncates at 8 KB | **both** backends | open (pjproject#5222) |
| Apple TLS backends unbuildable via CMake (`FATAL_ERROR "TODO"`) | both | open (pjproject#5223) |
| `apple` + non-select ioqueue builds but never connects | Apple | open (pjproject#5223) |
| `--enable-darwin-ssl` no-op; neither backend selectable from configure | build system | open (pjproject#5217, #5221) |
| Four unguarded paths in `get_cert_info()` (see pinning section) | **both** | open (pjproject#5224 review) |
| `get_cert_info()` leaks per renegotiation | **both** | open (pjproject#5215) |
| ~400 lines duplicated between the two backends | both | open (pjproject#5224) |

**Bottom line for us:** we ship the Apple/Network.framework backend, which is the one
without the crash and the one that already validates eagerly. What still touches our build
is the 8 KB truncation, the `get_cert_info()` robustness gaps if we ever pin against
untrusted peers, and the select-ioqueue constraint.

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
