# The `http2_body_preread_size` trap

**If you lowered `http2_body_preread_size` below 65535 as a hardening or
anti-flood measure, nginx is silently refusing every HTTP/2 request that carries
a body.** Every POST, every PUT, every RFC 8484 DoH POST. `nginx -t` passes, no
error appears at your log level, and GET requests work perfectly.

This was found on a live resolver where the value had been set to `16k` for
roughly three to four months. It had been tested from several phones and looked
fine, because the failure only shows up on one protocol-and-method combination.

## Symptoms

| Request | Result |
|---|---|
| GET over HTTP/2 | 200 |
| POST over HTTP/1.1 | 200 |
| POST over HTTP/3 | 200 |
| **POST over HTTP/2** | **connection reset** |

The client sees `REFUSED_STREAM`. curl reports:

```
* HTTP/2 stream 1 refused by server, try again on a new connection
* REFUSED_STREAM, retrying a fresh connect
* Connection died, retrying a fresh connect (retry count: 1)
```

It fails on **every path** - `/`, `/api/...`, even a URL that does not exist -
because the refusal happens in the connection layer before any routing. That is
the tell that distinguishes this from a location misconfiguration.

## Why

`src/http/v2/ngx_http_v2.c`, in `ngx_http_v2_state_headers()`:

```c
if (!h2c->settings_ack
    && !(h2c->state.flags & NGX_HTTP_V2_END_STREAM_FLAG)
    && h2scf->preread_size < NGX_HTTP_V2_DEFAULT_WINDOW)
{
    ngx_log_error(NGX_LOG_INFO, h2c->connection->log, 0,
                  "client sent stream with data "
                  "before settings were acknowledged");

    status = NGX_HTTP_V2_REFUSED_STREAM;
    goto rst_stream;
}
```

`NGX_HTTP_V2_DEFAULT_WINDOW` is **65535**. nginx's own default for
`preread_size` is **65536** - one byte above the threshold, which is why the
problem never appears until someone lowers it deliberately.

All three conditions hold in practice:

1. **`!h2c->settings_ack`** - clients send their first request immediately after
   the connection preface rather than waiting a round trip for the SETTINGS ACK.
   Effectively always true for the first request on a connection.
2. **`!END_STREAM`** - true for any request with a body. A GET sets END_STREAM on
   the HEADERS frame, which is exactly why GET is unaffected.
3. **`preread_size < 65535`** - true only if you lowered it.

The reason the guard exists is that this directive does double duty. Further down
the same file:

```c
buf->last = ngx_http_v2_write_uint16(buf->last,
                                     NGX_HTTP_V2_INIT_WINDOW_SIZE_SETTING);
buf->last = ngx_http_v2_write_uint32(buf->last, h2scf->preread_size);
```

**`http2_body_preread_size` is also the HTTP/2 INITIAL_WINDOW_SIZE that nginx
advertises.** Until the client acknowledges that SETTINGS frame it does not know
your window is smaller, so per RFC 7540 it may legally send up to the default
65535 bytes of body. A preread buffer smaller than that could not hold the
result, so nginx refuses the stream instead of risking
`http2 preread buffer overflow`.

So this is not an nginx bug. It is an unavoidable consequence of advertising a
window smaller than the protocol default, and nginx chooses to fail closed.

## Why it is so easy to miss

- **The log line is INFO.** A production `error_log ... error;` never shows it.
- **GET works**, so a browser loading your site is fine.
- **HTTP/1.1 works** (no SETTINGS mechanism) and **HTTP/3 works** (different
  module entirely), so many clients silently succeed or fall back.
- **`nginx -t` passes.** The configuration is valid; the behaviour is runtime.
- **`REFUSED_STREAM` is retryable by design**, so well-behaved clients retry
  rather than error loudly - which looks like nothing is wrong.

## How to measure it on your own server

Add a second `error_log` at INFO to a separate file, briefly. This changes no
behaviour:

```nginx
error_log /var/log/nginx/error.log error;      # keep your existing one
error_log /var/log/nginx/h2debug.log info;     # TEMPORARY
```

Reload, wait a few minutes, then count:

```sh
grep -c 'before settings were acknowledged' /var/log/nginx/h2debug.log

# who is affected
grep 'before settings were acknowledged' /var/log/nginx/h2debug.log \
  | grep -oP 'client: \K[0-9a-f.:]+' | sort | uniq -c | sort -rn
```

**Remove the INFO log afterwards** - it is very verbose on a busy server. Watch
disk while it runs.

Confirm your own reproduction before and after, and always keep controls:

```sh
curl -so /dev/null -w '%{http_code} %{http_version}\n' -X POST --data-binary @body.bin https://example.com/     # h2
curl -so /dev/null -w '%{http_code} %{http_version}\n' --http1.1 -X POST --data-binary @body.bin https://example.com/
curl -so /dev/null -w '%{http_code} %{http_version}\n' --http3-only -X POST --data-binary @body.bin https://example.com/
```

## Measured impact and cost

On the deployment where this was found, a 7-minute INFO window recorded **145
refused streams from 9 distinct real client IPs**, roughly 1,240/hour. Individual
clients were **retry-looping** rather than falling back - 63 attempts from a
single address in seven minutes.

That last detail is worth sitting with: the setting was chosen to reduce load
under flood, and it was *generating* flood-shaped retry traffic from legitimate
clients. Each affected user produced a stream of connection attempts instead of
one successful request.

Raising it to `65535` and measuring for 13 minutes:

| `http2_body_preread_size` | samples | nginx RSS mean | RSS range |
|---|---|---|---|
| 16k | 4 | 86.0 MB | 86 |
| **65535** | 53 | **88.5 MB** | 84-91 |

**About +2.5 MB (~3%), with no upward drift** - a steady-state shift, not a leak.

The cost is real but bounded. The buffer is allocated in full per body-carrying
stream (`ngx_create_temp_buf(r->pool, h2scf->preread_size)`), so the worst case
is `http2_max_concurrent_streams` x 64k per connection, capped further by your
`limit_conn` settings. Note that a small `client_max_body_size` does **not**
shrink the allocation.

## What to do

**Keep `http2_body_preread_size` at 65535 or above.** nginx's default (65536) is
correct; there is no reason to lower it. The threshold is a hard `< 65535`
comparison, so there is no middle ground - any smaller value refuses all
body-carrying HTTP/2 streams.

If you genuinely need to bound HTTP/2 memory, the directives that do that
without breaking requests are `http2_max_concurrent_streams`,
`client_max_body_size`, `client_body_buffer_size`, and `limit_conn`. See
[`../examples/anti-ddos.conf`](../examples/anti-ddos.conf).

## The general lesson

A hardening change that reduces a limit below a protocol default can convert a
capacity control into an availability failure - and the failure can be invisible
if it lands on one protocol path, logs below your level, and manifests as a
retryable error that clients paper over.

After tightening any limit, verify the thing you tightened still *works*, not
just that `nginx -t` passes and the site loads. `nginx -t` validates syntax, not
behaviour.
