# Transparent HTTPS for secret gateways

Spike for phase 8.4. The policy in `TransparentHTTPS` is tested. Terminating
TLS inside the egress proxy is not implemented: it has to live in
`EgressProxy`, which stays untouched until `impro-ref` lands. A second proxy
in front of it would copy the public-unicast filter and could drift from it,
which would weaken the cage. That shape was rejected.

## What it is for

Gateway delivery gives the agent a placeholder and a loopback base URL. SDKs
that ignore the base-URL variable still call the real host with the
placeholder in a header. Transparent mode is the fallback for those SDKs:
the cage's HTTPS proxy decrypts only those hosts, swaps the placeholder for
the real value, and encrypts onward. Every other connection stays the blind
tunnel the proxy already is.

## Decision

`TransparentHTTPS.decision(host:secretUpstreams:)` returns `terminate` only
when the CONNECT host is exactly a host named by a secret's gateway
upstream. The comparison is a lowercased DNS name of two or more labels.
These stay tunnels:

- any other name, including a suffix or a prefix of an upstream
  (`evil.api.openai.com`, `api.openai.com.evil.test`)
- IP addresses and `localhost`
- a host the existing egress policy did not already allow

Termination never bypasses `EgressHostPolicy`. The proxy allows the CONNECT
first; only then does this decision choose terminate or tunnel.

## Certificate

One CA per rv install. The private key is a Keychain item
(`rv.transparent-ca`) on macOS and an owner-only file on Linux. The CA is
not added to the host trust store. The cage receives it only through
`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, and
`CURL_CA_BUNDLE`, pointed at a file inside the scratch directory. A process
outside the cage does not trust it.

## Request path

1. The cage CONNECTs to `api.example.com:443` through the existing proxy.
2. The proxy applies today's filter (allowlist or public HTTPS, then the
   public-unicast dial check). A denial is unchanged.
3. If the host is not a secret upstream, the proxy dials and relays bytes.
   It does not look at them.
4. If it is, the proxy completes a TLS handshake with a leaf signed by the
   install CA, reads the HTTP request, replaces a placeholder it issued for
   that upstream, and opens its own TLS connection to the real host with the
   system trust store. The response is streamed back. Bodies are not logged.
   The placeholder and the real value are scrubbed the way the gateway
   already scrubs them.

## Not in this spike

Minting the CA, the handshake, and the header swap. Those belong in
`EgressProxy` after `impro-ref`. Until then, SDKs that honor
`baseURLEnv` keep using the loopback gateway.
