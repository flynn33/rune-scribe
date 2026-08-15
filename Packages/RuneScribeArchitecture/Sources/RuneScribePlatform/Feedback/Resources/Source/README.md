# Generic unlock fallback sounds

These four mono PCM WAV files are generic application fallbacks. They are not
Theme content and contain no recorded or licensed samples.

Regenerate them offline from this directory:

```sh
swift make_fallback_sounds.swift
```

The source uses fixed-point phase, envelopes, and an integer-only oscillator,
so the PCM bytes are reproducible. It does not use the network, microphones,
sample libraries, or an audio session.

| Resource ID | File | Duration | SHA-256 |
| --- | --- | ---: | --- |
| `audio.unlock.micro.default` | `unlock_micro.wav` | 0.55 s | `49c4cfb544be9dc7d42d31cc6f1da82fcc96e02fd78ee7ca60f165d1a0eaa8c5` |
| `audio.unlock.artifact.default` | `unlock_artifact.wav` | 1.00 s | `3e0aad842b786515a43e3942d0b0ec8519396efccdb2d2b738ccf07984d9da7d` |
| `audio.unlock.codex.default` | `unlock_codex.wav` | 1.75 s | `fa23a17ee1af6e845b77f9079b49d4b26921bdeb7cf3d30f45db5510df99719b` |
| `audio.unlock.mastery.default` | `unlock_mastery.wav` | 2.20 s | `1e23ca022369024eb2339f7d7738841011041095d62bc9a285583be37325af31` |

All files use 22,050 Hz, 16-bit mono linear PCM. Automated tests pin the exact
digests, channel count, duration, conservative peak, and combined size.
