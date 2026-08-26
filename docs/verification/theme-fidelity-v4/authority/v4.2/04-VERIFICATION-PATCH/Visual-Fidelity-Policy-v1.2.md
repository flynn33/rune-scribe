# Visual Fidelity Policy v1.2

## Exact mapping

Every reference must use its exact mapping in `Comparison-Authority-v1.2.json`. The runner may not choose a nearby element, infer a crop, reuse a different state, or replace a missing focal capture with a whole-screen screenshot.

## Full-screen role

Use only for an approved final in-application screen on a declared compatible destination. Capture the exact screen wrapper and mask platform-owned chrome only.

## Focal role

Capture exact accessibility-element bounds or the complete deterministic renderer output. Use the complete supplied reference. Aspect-fit and pad; never crop opaque reference or candidate pixels.

## Structural-only role

Use when a complete board or differently sized approved screen controls hierarchy, state, materials, and composition but is not a truthful same-aspect pixel golden. No pixel score is claimed. Reference hash, exact candidate capture, and every structural assertion are blocking.

## Negative invariant

Used only for the prohibited Norse locked production state. All exact probes are blocking.

## Reduce Motion

Visual mappings, runtime behavior, temporal stability, and preview containment are all required. A duplicated standard screenshot is not evidence.

## Protection

Do not replace approved references with implementation output. Do not weaken thresholds, enlarge masks, create freehand crops, omit failed records, or rename candidate IDs to match whatever is easiest to capture.
