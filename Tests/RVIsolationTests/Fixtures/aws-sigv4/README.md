# AWS Signature Version 4 test vectors

Known-answer vectors for `AWSSigV4` (`Sources/RVIsolation/SecretGatewaySigV4.swift`),
driven by `Tests/RVIsolationTests/SecretGatewaySigV4Tests.swift`.

- Source: https://github.com/awslabs/aws-c-auth, `tests/aws-signing-test-suite/v4/`
- Commit: `3d29adcecf5c032131acee9f4125a636d2aaea6a` (2026-10-26)
- License: Apache-2.0, copyright Amazon.com, Inc. or its affiliates.

Only the header-signing files are copied, unmodified: `context.json`,
`request.txt`, and `header-{canonical-request,string-to-sign,signature,signed-request}.txt`.
rv never presigns query strings, so the `query-*` files are left out.

The credentials in `context.json` are AWS's published example keys
(`AKIDEXAMPLE`), not real secrets.
