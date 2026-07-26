# nginx-edge

Build tooling for a **BoringSSL-linked nginx with HTTP/3, Encrypted Client Hello
and Brotli**, compiled for AMD Zen 2 — as deployed on the
[dnsdoh.art](https://dnsdoh.art) edge (AMD EPYC 7542, Debian, KVM VPS).

Currently running **nginx 1.31.3** (mainline) against **BoringSSL
`0.20260713.0`**, the same BoringSSL release tag used by
[unbound-edge](https://github.com/Ozy-666/unbound-edge).

```
nginx 1.31.3  ·  BoringSSL 0.20260713.0  ·  ngx_brotli  ·  jemalloc
TLS 1.3 + X25519MLKEM768 · HTTP/3 (QUIC) · ECH · -march=znver2 -flto
```

**What this repo is:** an update script that fetches, verifies, builds and
hot-swaps nginx without downtime; the ECH patch that makes `ssl_ech_file`
actually work on BoringSSL; and annotated example configuration for TLS
hardening and L7 DDoS mitigation.

**What this repo is not:** a fork of nginx, and not our production
configuration. No nginx source is vendored here — `nginx-update.sh` downloads
the official nginx.org tarball at build time. The single exception to
"no source changes" is `ech-boringssl.patch`, applied at build time and
documented below.

> The live `nginx.conf` is deliberately not published. Rate-limit thresholds,
> upstream addresses and cache-key structure lose most of their value once
> public — an attacker who knows your limits simply stays under them. The
> `examples/` directory carries the same techniques with placeholder values and
> the reasoning behind each one, which is the part that transfers anyway.

---

## Contents

| Path | What it is |
|---|---|
| [`nginx-update.sh`](nginx-update.sh) | Fetch → PGP-verify → patch → build → test → hot upgrade |
| [`ech-boringssl.patch`](ech-boringssl.patch) | Server-side ECH for BoringSSL builds |
| [`examples/tls-hardening.conf`](examples/tls-hardening.conf) | TLS 1.3 / HTTP/3 template, and how to score A+ on SSL Labs |
| [`examples/anti-ddos.conf`](examples/anti-ddos.conf) | Rate limiting, connection limits, slowloris defence |
| [`docs/tls-testing.md`](docs/tls-testing.md) | Testing beyond SSL Labs — what it misses and what covers it |

---

## Why BoringSSL

BoringSSL is what Google runs in Chrome and on their frontends, and it brings
three things OpenSSL does not offer here:

- **Server-side ECH.** BoringSSL has a working `SSL_ECH_KEYS_*` API. OpenSSL's
  ECH support lives in a long-running fork rather than upstream.
- **Equal-preference cipher groups** — the `[A|B]` syntax, which lets a client
  with AES hardware pick AES-GCM and a client without pick ChaCha20-Poly1305 at
  the *same* priority. Genuinely useful on mixed mobile traffic, and not
  expressible in OpenSSL's cipher string language.
- **Post-quantum key exchange** (`X25519MLKEM768`) shipped early and stable.

The costs are real and worth stating plainly:

- **No OCSP stapling.** BoringSSL removed the OCSP APIs nginx depends on.
  `ssl_stapling on;` parses, emits `[warn] "ssl_stapling" ignored, not
  supported`, and does nothing — `nginx -t` still reports success, so it is easy
  to believe you have stapling when you do not. Verified on this build. If
  stapling is a hard requirement, build against OpenSSL instead.
- **No stable ABI** — nginx must be recompiled whenever BoringSSL is bumped.
- **`ssl_conf_command Ciphersuites` is a no-op**, because BoringSSL does not
  expose TLS 1.3 suite ordering; `ssl_ciphers` affects TLS 1.2 only.

### Post-quantum key exchange

The complete set of groups supported by BoringSSL `0.20260713.0`, read from
`kNamedGroups` in `ssl/ssl_key_share.cc`. All seven are accepted by
`ssl_ecdh_curve` — verified with `nginx -t` on this build — but only one belongs
in a public config:

| Group | Kind | Verdict |
|---|---|---|
| `X25519MLKEM768` | hybrid X25519 + ML-KEM-768 | **use this** |
| `MLKEM1024` | pure ML-KEM, no classical half | avoid — no fallback if lattices break |
| `X25519Kyber768Draft00` | pre-standard Kyber draft | obsolete, not interoperable with ML-KEM |
| `X25519` | classical | keep, as fallback |
| `P-256` / `P-384` / `P-521` | classical | P-521 rarely worth it |

BoringSSL's own default order is `X25519MLKEM768, X25519, P-256, P-384` —
it excludes P-521, MLKEM1024 and the Kyber draft, which is a useful signal.

The urgency is **harvest-now-decrypt-later**: traffic recorded today can be
decrypted once a quantum computer exists, and a session's confidentiality is
settled permanently at the moment it happens. Signatures are not urgent in the
same way — a forgery must be produced *during* the handshake — which is why PQ
key exchange matters now and PQ certificates can wait for the WebPKI.

Counterintuitively the cost is **bandwidth, not CPU**: ML-KEM is lattice
arithmetic and is cheaper than EC scalar multiplication, but its 1184-byte keys
push the ClientHello past a typical MTU. Full reasoning, including why
`MLKEM1024` alone is the wrong choice despite a higher security category, is in
[`examples/tls-hardening.conf`](examples/tls-hardening.conf).

### Two BoringSSL checkouts, deliberately

This build uses a **dedicated** BoringSSL checkout (`boringssl-nginx`) that
tracks the latest release tag and produces **static** `libssl.a` / `libcrypto.a`.
It is separate from the pinned, **shared-library** checkout that
[unbound-edge](https://github.com/Ozy-666/unbound-edge) uses. Conflating them
breaks one or both — there is no stable ABI between BoringSSL releases, so every
dependent has to be rebuilt when its own checkout moves.

nginx tracks the latest tag rather than pinning because the pre-install gate
(below) makes a bad release fail safely, before the running binary is touched.

---

## Encrypted Client Hello on BoringSSL

nginx ships the `ssl_ech_file` directive, but its implementation targets the
OpenSSL-ECH API and is guarded by `SSL_OP_ECH_GREASE` — which BoringSSL does not
define. On a BoringSSL build the directive is accepted and then does nothing,
silently. `ech-boringssl.patch` adds a BoringSSL branch in
`src/event/ngx_event_openssl.c` using `SSL_ECH_KEYS_new` / `SSL_ECH_KEYS_add` /
`EVP_HPKE_KEY_init`.

The patch is applied idempotently — the script checks for `SSL_ECH_KEYS_add` in
the tree and skips if already present, so re-runs never double-apply.

**ECH fails silently by design.** A broken deployment is indistinguishable from
no ECH at all from the outside, so verify it explicitly rather than assuming;
see [`docs/tls-testing.md`](docs/tls-testing.md). The ECHConfigList you serve
must match the HTTPS/SVCB record published in DNS, and the two must be rotated
together.

---

## Supply-chain verification

nginx.org publishes a detached PGP signature for every release but **no
SHA256 checksum**, so PGP is the only integrity check available — and the script
treats a failure as fatal rather than a warning.

- Signing keys are fetched from `https://nginx.org/keys/` and imported **only if
  their fingerprint appears in a pinned allowlist** in the script, so a
  compromised keys page cannot introduce a new signer.
- Import happens into a throwaway keyring under the build directory; your real
  GNUPGHOME is never touched.
- After verification the signer's fingerprint is checked against the allowlist a
  second time, so a good signature from an unpinned key is still rejected.
- `NGINX_SKIP_PGP=1` bypasses the check for airgapped builds, loudly.

Refresh the pinned list from
[nginx.org/en/pgp_keys.html](https://nginx.org/en/pgp_keys.html) when nginx adds
a maintainer — an unknown signer is treated as a failure, not a prompt.

---

## Build and deploy

```sh
git clone https://github.com/Ozy-666/nginx-edge
cd nginx-edge
./nginx-update.sh
```

The script, in order:

1. Backs up the current binary and `/etc/nginx` (timestamped tarball).
2. Updates `ngx_brotli` and its submodules.
3. Resolves the latest BoringSSL release tag, builds static `libssl.a` /
   `libcrypto.a` with Ninja.
4. Resolves the latest nginx mainline version, downloads it, **verifies the PGP
   signature**, extracts.
5. Applies `ech-boringssl.patch` if not already present.
6. Configures and compiles with `-O3 -march=znver2 -mtune=znver2 -flto`,
   linking jemalloc.
7. **Gates on the new binary before installing it** — runs `nginx -t` against
   your live config with the freshly built binary, and confirms it reports
   BoringSSL. A failure aborts with the running nginx untouched.
8. `make install`, then a `USR2` / `WINCH` / `QUIT` hot upgrade — zero dropped
   connections, with a `systemctl restart` fallback if the new master fails to
   appear.

**Adapt before running on another host.** `-march=znver2` targets Zen 2 and will
produce a binary that will not run on older CPUs; `CORES=4` and the paths at the
top of the script are specific to this deployment.

### Rollback

`make install` renames rather than overwrites, so the previous binary is always
recoverable:

```sh
mv /usr/sbin/nginx.old /usr/sbin/nginx   # or nginx.backup.<timestamp>
systemctl restart nginx
```

(Related note from the unbound side of this stack: installing over a **live
shared object** with `cp` truncates the mmap'd inode and segfaults the running
process. nginx is unaffected — its `make install` does `mv` then `cp`, and this
build links BoringSSL statically anyway.)

---

## Configuration examples

Two annotated templates, both with placeholder values:

- **[`examples/tls-hardening.conf`](examples/tls-hardening.conf)** — protocol and
  cipher selection for BoringSSL, key exchange including post-quantum hybrid,
  the session-ticket trade-off, 0-RTT and RFC 8470, OCSP stapling, ECH, security
  headers, and a full walkthrough of **what SSL Labs actually measures and how
  to reach A+** (the answer is one directive, and it commits you to more than
  people expect).
- **[`examples/anti-ddos.conf`](examples/anti-ddos.conf)** — **two-tier limiting**
  (per-IP *and* a per-vhost circuit breaker, because per-IP limits alone do
  nothing against a botnet where every host stays under the threshold), QUIC
  address validation with `quic_retry`, `max_ranges` against range
  amplification, `max_headers`, slowloris timeout tuning, HTTP/2 and HTTP/3
  stream caps, `ssl_reject_handshake` for unknown-Host scanners, and — the part
  most guides omit — **how to derive your own thresholds from your access log**
  instead of copying someone else's numbers.

Neither is a drop-in. Rate limits copied from a stranger's blog either throttle
your users or stop nothing.

> **`anti-ddos.conf` is one layer, not a solution.** nginx only sees traffic
> that already reached your NIC, survived any XDP/nftables filtering, and
> completed TCP/QUIC *and* TLS handshakes. A volumetric L3/L4 flood is decided
> before nginx is consulted, and a TLS handshake flood spends your CPU before
> any `limit_req` is evaluated — rate limiting acts on requests, and a handshake
> is not yet a request. The file opens with the full layer diagram and closes
> with an explicit list of what it does **not** protect against. The
> complementary half — filtering below nginx — is deliberately unpublished,
> since a public anti-DDoS ruleset is a public bypass guide.

---

## Related repositories

Part of the DNS and edge stack behind [dnsdoh.art](https://dnsdoh.art):

```
nginx-edge (this repo)   443 HTTPS + HTTP/3, ECH
AGH-Edge   443 DoH + DoH3 · 853 DoT + DoQ · 53 plain
  └─> Unbound  127.0.0.1:5353   ← unbound-edge (DNSSEC validation)
        └─> dnscrypt-proxy  127.0.0.1:5053
              └─> encrypted upstreams
```

- **[unbound-edge](https://github.com/Ozy-666/unbound-edge)** — BoringSSL-linked,
  Zen 2-optimised Unbound build tooling and config. Closest sibling to this repo.
- **[dnscrypt-proxy](https://github.com/Ozy-666/dnscrypt-proxy)** — fork carrying
  the encrypted-upstream path for this stack.
- **[AdGuardHome-edge-spec](https://github.com/Ozy-666/AdGuardHome-edge-spec)** —
  public specification and optimisation logs for the AdGuardHome/dnsproxy layer.
- **[dns-ultra](https://github.com/Ozy-666/dns-ultra)** — finds the fastest DNS
  resolvers for a dnscrypt-proxy setup using real queries rather than synthetic
  pings.

---

## License

The build script, patch, examples and documentation in this repository are
released under the **2-clause BSD License**, matching nginx's own.

nginx is © Nginx, Inc. and F5, under the 2-clause BSD License.
BoringSSL is © Google, under its own licence terms.
`ngx_brotli` is © Google, under the MIT License.
Neither project is affiliated with or endorses this repository.
