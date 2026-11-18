# Vendored OCSF 1.3.0 schemas

JSON Schemas for the six OCSF event classes `rv audit export --format ocsf`
and `rv audit forward` emit, exported by the OCSF schema server for OCSF
**1.3.0** with the profiles each class declares in `metadata.profiles`.
`AuditOCSFSchemaTests` runs one event of every audit kind through
`AuditOCSF` and checks it against these files with the small validator in
`OCSFSchemaValidator.swift` (no JSON Schema dependency).

| File | Class | rv kinds |
| --- | --- | --- |
| `api_activity@host.json` | 6003 API Activity | `mcp.call`, `mcp.approval`, `secret.use` |
| `application_lifecycle@host.json` | 6002 Application Lifecycle | `runtime.*`, `admission`, `workspace.*`, `agent.*`, `mcp.tool.changed`, `mcp.hosts.ungoverned`, `command.override`, `owner.action` |
| `detection_finding@host+security_control.json` | 2004 Detection Finding | `secret.misuse` |
| `device_config_state_change@host.json` | 5019 Device Config State Change | `policy.changed`, `policy.managed`, `config.changed` |
| `network_activity@host+security_control.json` | 4001 Network Activity | `egress.denied`, `egress.observed` |
| `process_activity@host+security_control.json` | 1007 Process Activity | `command.denied`, `command.observed` |

Each file is a class export: the class, every object it references
(`$defs`), and their enumerations. The file name is
`<class>@<profile>+<profile>.json`, profiles sorted, and the validator
picks the file from an event's `class_uid` and `metadata.profiles`.

## Source and licence

- Source: the OCSF schema server, `https://schema.ocsf.io`, version 1.3.0,
  built from `https://github.com/ocsf/ocsf-schema` (tag `v1.3.0`).
- Fetched 2026-11-18, reformatted with `python3 -m json.tool --indent 2`,
  otherwise unchanged.
- Licence: Apache License 2.0, copyright the OCSF contributors. The licence
  text is in `LICENSE` beside this file.

## Refreshing or adding a class

From this directory, for each file (profiles comma-separated in the URL):

```sh
curl -sSfL "https://schema.ocsf.io/schema/1.3.0/classes/network_activity?profiles=host,security_control" \
  | python3 -m json.tool --indent 2 > 'network_activity@host+security_control.json'
```

An export can take a minute or two. A mapper change that emits a new class
or profile set fails `everyEmittedClassHasAVendoredSchema` until its file is
added here; a vendored file no event uses fails the same test.

## Known deviations

OCSF 1.3.0 applies the `security_control` profile (`action`, `action_id`,
`disposition`, `disposition_id`) only to some classes, and API Activity has
no `device`; Detection Finding has no `is_alert` until a later OCSF version.
rv emitted those attributes on every class before this check
existed, and SIEM rules read them, so they stay. They are listed in
`AuditOCSFSchemaTests.knownDeviations`; every other attribute must be
defined by the schema, and the list fails the test when an entry is no
longer emitted.
