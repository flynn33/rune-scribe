# Platform Notes

Rune Scribe shares the same encrypted payload formats across macOS and iOS, but the
operating systems expose different intake paths.

## Cipher Import on macOS

Automatic cipher import from Messages is not supported on Mac. A `.runescribe`
cipher file received in Messages does not silently add itself to the cipher library.

On macOS, import a cipher by one of these supported paths:

- Open **Cipher Library > Import** and choose the `.runescribe` file.
- Open a saved `.runescribe` file with Rune Scribe.
- Paste a `runescribe://` import link into Rune Scribe.

The imported cipher is still validated on-device before it is saved. The payload must
have the expected version, byte length, rune permutation, and checksum.

## iOS Intake

iOS supports the one-tap Messages attachment flow for `.runescribe` files. When a
first message includes an embedded cipher key, opening the attachment can import the
key, decrypt the message, and file the cipher under the sender.

The same privacy rule applies on both platforms: a `.runescribe` file or import link
carries the actual cipher key. Share it only through a private channel.
