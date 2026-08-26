# Executable Reference Mapping Decision

Every approved reference is now bound one-to-one to an exact candidate source for every destination. The matrix contains 400 entries and 1104 mapping instances.

A mapping is executable only when it contains exactly one of:

- `candidateElementID`;
- `candidateRendererOutputID`;
- `candidateProbeID` for a declared negative invariant.

Every mapping also declares a full-image source crop, exact candidate focal rule, reference role, score disposition, normalization policy, threshold profile, and any structural assertions.

Freehand reference crops, freehand candidate crops, custom masks, nearest-element substitutions, and operator-selected mappings are prohibited. Missing exact identifiers are implementation work, not a reason to request new owner input.
