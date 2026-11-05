# Changelog

## Unreleased

- Action fingerprints now use an injective encoding. Pending runtime-HTTP asks, and pending asks for commands containing `:`, `,` or `\`, created before upgrade are re-asked after upgrade. Existing grants are unaffected.
