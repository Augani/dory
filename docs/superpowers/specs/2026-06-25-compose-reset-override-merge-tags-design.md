# Compose `!reset` / `!override` merge tags

Date: 2026-06-25
Status: Approved (design)

## Problem

Dory's Compose multi-file merge (`ComposeModel.merge`) deep-merges fields by rule
(env/labels keyed, ports/dns concatenated, volumes/devices target-merged, mappings recursive).
The Compose spec lets an override file opt out of those rules per value:

- `!override <value>` — replace the base value entirely instead of merging.
- `!reset <value>` — remove the key from the merged result (undo an earlier file).

`YAMLValue` has no way to carry a tag, so today `!reset`/`!override` would be parsed as plain
strings and ignored. This adds **inline** tag support (tag immediately before a same-line value).

## Scope

In scope: inline placement only — `ports: !reset null`, `command: !override [a, b]`,
`environment: !override {X: "1"}`.

Out of scope: block placement (`key: !override` with the value indented on following lines);
other parity items; non-Compose YAML.

## Design

### 1. `YAMLValue`
Add `case tagged(MergeTag, YAMLValue)` with `enum MergeTag: Sendable { case reset, override }`.
The accessors (`stringValue`, `mappingValue`, `sequenceValue`, `boolValue`, `stringList`,
`subscript`) transparently unwrap `.tagged` to the inner value, so `parseService` and other
consumers are unaffected. `ComposeInterpolation.interpolate`'s exhaustive `switch` is
compiler-forced to handle the new case (recurse into the inner value, re-wrap the tag).

### 2. Parser (`YAMLParser`)
`scalarOrFlow` — the single inline-value entry point used by block mappings, block sequences,
and inline-mapping items — detects a leading `!reset`/`!override` **token** (the tag followed by
whitespace or end-of-string; quoted values like `"!reset"` are unaffected because the quote is
checked first). It strips the tag, parses the remainder via `scalarOrFlow` (empty remainder →
`.null`), and wraps the result in `.tagged`.

### 3. Merge (`ComposeModel.merge`)
- At the top, before any field-specific rule: `.tagged(.override, v)` → return `stripTags(v)`
  (replace, bypassing keyed/concatenated/target/recursive merge).
- In the mapping-merge loop: a value of `.tagged(.reset, _)` removes the key (`merged[key] = nil`)
  instead of merging; an override-only key is assigned `stripTags(value)`.
- `stripTags(_:)` recursively removes `.tagged` wrappers (override → inner, reset → its inner/null)
  so the first (base) file's own tags and any residual tags never reach `parseService`. Applied
  inside the merge branches above; merges run in order so later-file tags act on the
  already-stripped base.

## Testing (TDD)

- `!override` on a concatenated field (`ports`) replaces instead of appending.
- `!override` on a keyed field (`environment`) replaces the whole mapping instead of key-merging.
- `!reset` removes a key that the base file set.
- `!reset` / `!override` in a single (non-merged) file collapse to plain values (strip).
- Regression: existing tag-free merge behavior is unchanged (`mergesComposeFilesWithDockerOverrideRules`
  still passes).
- Parser: `scalarOrFlow("!override [a, b]")` → `.tagged(.override, .sequence([...]))`;
  `"!reset"` (bare) → `.tagged(.reset, .null)`; quoted `"\"!reset\""` stays a string.

## Risks

The YAML reader is hand-rolled. Centralizing detection in `scalarOrFlow` keeps the change to one
function plus the `YAMLValue` case; the exhaustive-switch compile error guards the interpolation
path. Inline-only scope avoids touching the block-mapping line loop.
