# Controlling Decision — Reduce Motion Evidence

## Decision

A single still screenshot cannot prove motion suppression. Reduce Motion acceptance is a combined runtime-behavior and static-visual gate.

## Required evidence for every Theme and destination

1. Accessibility environment reports Reduce Motion enabled.
2. The effective visual plan identifies the Theme's Reduce Motion resource or an explicitly motionless standard resource.
3. Theme motion policy resolves to `none`, `off`, or the repository's equivalent no-motion state.
4. Active Theme animation count is zero, or all remaining animations are proven platform-essential and outside Theme presentation.
5. Capture A and Capture B are taken at least 1.5 seconds apart after the UI settles.
6. Every region declared static under Reduce Motion remains stable between A and B, excluding only platform cursor, status-clock, and scrollbar pixels.
7. The required Relic/artifact preview exists, is visible, and is fully contained in the application viewport.
8. The static visual still matches its approved Theme authority through the focal comparison profile.

## Failure cases

Fail when the preview is missing, clipped, blank, still animating, bound to the standard motion resource when a separate Reduce Motion resource is declared, or supported only by a duplicated screenshot without runtime evidence.
