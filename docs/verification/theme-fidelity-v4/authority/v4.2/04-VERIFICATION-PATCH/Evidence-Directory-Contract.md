# Evidence Directory Contract

Create new evidence under:

`docs/verification/theme-fidelity-v4/`

Minimum structure:

```text
authority/
baseline/
final/
comparisons/
focal-captures/
heatmaps/
reduce-motion/
responsive-layout/
negative-mutations/
test-runs/
source-manifests/
FinalSelfAudit.md
```

Every generated record includes the final source SHA, comparison-authority SHA, asset-manifest SHA, command, timestamps, destination, toolchain, result, failures, and output hashes. No current acceptance checker may treat a historical result file as proof for the v4 branch.
