# Testing a TLS deployment — beyond SSL Labs

[Qualys SSL Labs](https://www.ssllabs.com/ssltest/) is the default reference and
deserves to be. It is also TCP-only, HTTP-focused, and blind to several things
this build specifically does. Below is what it covers, what it misses, and what
to use for the gaps.

## The structural gaps in SSL Labs

For a build like this one, a clean A+ leaves the following **completely
ungraded**:

| Feature | Covered by SSL Labs? |
|---|---|
| TLS 1.2 / 1.3 over TCP | yes — this is its whole job |
| Certificate chain, revocation, CAA | yes |
| HSTS | yes (and it is the only thing separating A from A+) |
| **HTTP/3 and QUIC** | **no** — the scanner does not speak QUIC |
| **Encrypted Client Hello** | **no** |
| **Post-quantum key exchange** (X25519MLKEM768) | **no** — not reflected in the grade |
| **Security headers** other than HSTS | **no** |
| Non-443 ports, STARTTLS, internal hosts | no — public 443 only |

If most of your interesting configuration is in that lower half, SSL Labs is a
floor, not a verdict.

## General-purpose alternatives

**[testssl.sh](https://testssl.sh/)** — the most useful complement, and the one
to reach for first. Open-source bash, runs from your own machine, so nothing is
submitted to a third party and you can point it at internal hosts, arbitrary
ports, and STARTTLS services. It also enumerates the actual negotiated suites
rather than inferring a grade.

```sh
git clone --depth 1 https://github.com/testssl/testssl.sh
cd testssl.sh && ./testssl.sh --full example.com

# Fast, high-signal subset: protocols, forward secrecy, groups/KEMs
./testssl.sh -p -f -g --quiet example.com

# Or targeting a specific service:
./testssl.sh --starttls smtp mail.example.com:587
```

The `-g` flag is the one to know if you care about post-quantum — it reports
negotiated KEMs separately from classical curves, which no browser-facing
grader currently does. Abridged output from a build configured as in
`../examples/tls-hardening.conf`:

```
 TLS 1.2                      offered (OK)
 TLS 1.3                      offered (OK): final
 QUIC                         Local problem: No OpenSSL QUIC support
 FS is offered (OK)           TLS_AES_256_GCM_SHA384
                              TLS_CHACHA20_POLY1305_SHA256
                              ECDHE-ECDSA-CHACHA20-POLY1305
                              TLS_AES_128_GCM_SHA256
                              ECDHE-ECDSA-AES128-GCM-SHA256
 KEMs offered                 X25519MLKEM768
 Elliptic curves offered:     prime256v1 secp384r1 X25519
 TLS 1.3 sig_algs offered:    ECDSA+SHA256
```

Two things to read out of that:

- `KEMs offered: X25519MLKEM768` is the confirmation that post-quantum key
  exchange is actually negotiating, not merely configured. Nothing in an SSL
  Labs report tells you this.
- `QUIC: Local problem: No OpenSSL QUIC support` — testssl.sh does not speak
  QUIC either. **No general-purpose grader currently tests your HTTP/3 path.**
  You have to do it yourself with `curl --http3-only`.

testssl.sh also reads the DNS HTTPS/SVCB record, so it will show your published
`ech=` value and ALPN list — a quick way to confirm the ECHConfigList in DNS
matches what nginx is serving.

**[Hardenize](https://www.hardenize.com/)** — built by Ivan Ristić, who created
SSL Labs, and now part of Red Sift. Much broader scope: TLS plus DNS, DNSSEC,
email authentication (SPF/DKIM/DMARC/MTA-STS) and headers, presented as one
posture view. The closest thing to "SSL Labs for the whole domain".

**[Internet.nl](https://internet.nl/)** — funded by the Dutch government and
internet community. Notably strict, and unusually relevant to a DNS-adjacent
stack: it grades IPv6 reachability, DNSSEC validation, RPKI, TLS and security
headers together. Expect a worse score here than on SSL Labs; the extra
deductions are usually legitimate.

**[CryptCheck](https://cryptcheck.fr/)** — open source, and grades cipher and
key-exchange choices more harshly than SSL Labs. Useful as a second opinion when
you want to know whether an A+ is comfortable or marginal.

## Security headers

**[Mozilla HTTP Observatory](https://developer.mozilla.org/en-US/observatory)** —
moved to MDN from its old standalone domain. Scores CSP, HSTS, cookies,
referrer policy, subresource integrity, and explains each deduction.

**[securityheaders.com](https://securityheaders.com/)** — Scott Helme's scanner.
Headers only, near-instant, good for a quick regression check after a config
change. Do not treat its grade as a security assessment; a site can score A+
here and be trivially broken elsewhere.

## HTTP/3, QUIC and ECH

None of the graders above will exercise these. Test them directly:

```sh
# HTTP/3 — requires a curl built with HTTP/3 support
curl -sI --http3-only https://example.com | head -1

# Confirm Alt-Svc advertises h3 over the TCP path
curl -sI https://example.com | grep -i alt-svc

# What the server actually negotiated, per connection
curl -s -o /dev/null -w '%{http_version} %{tls_version} %{tls_cipher}\n' https://example.com
```

For **ECH**, Cloudflare hosts a client-side check that reports whether your
browser negotiated it, and Chrome/Firefox devtools will show the outer SNI. The
server side is best confirmed with a `bssl client` handshake against your own
`ssl_ech_file` config, since ECH failures degrade silently to plain SNI — a
misconfigured ECH deployment looks exactly like no ECH at all from the outside.

Verify the ECHConfigList you serve matches the HTTPS/SVCB record in DNS:

```sh
dig +short HTTPS example.com
```

## DNS and DNSSEC

Relevant if you run your own resolver or authoritative zone:

- **[DNSViz](https://dnsviz.net/)** — visualises the DNSSEC chain of trust and
  pinpoints exactly where validation breaks.
- **[Zonemaster](https://zonemaster.net/)** — run by IIS and AFNIC; thorough
  delegation and zone correctness checks.

## A practical routine

1. `testssl.sh` locally on every config change — fast, private, catches
   regressions before anything is published.
2. SSL Labs after a certificate or protocol change — it is what auditors and
   customers will run.
3. Internet.nl or Hardenize quarterly — they catch drift in the areas nobody
   watches (DNSSEC, email auth, IPv6).
4. `curl --http3-only` and a `dig HTTPS` check in monitoring, since no external
   grader will tell you when h3 or ECH quietly stops working.

> Availability and URLs of third-party scanners change. If one of the above has
> moved, `testssl.sh` is self-hosted and will keep working regardless.
