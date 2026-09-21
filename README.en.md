# PhoneSnap

**Send an iPhone screenshot to your Mac with one Shortcut trigger. Local-first, with an optional self-hosted encrypted relay.**

[中文说明](README.md) · [Setup](docs/SETUP.md) · [Relay](relay/README.md) · [Security](SECURITY.md)

This is a **source-only developer preview** derived from [Aqu1bp/PhoneSnap](https://github.com/Aqu1bp/PhoneSnap), not an official upstream release. Parts of the Mac editor come from [recursivecodes/grabbit](https://github.com/recursivecodes/grabbit). Original MIT notices are preserved.

## The workflow

1. Pair the standalone iPhone app with your Mac using a privately exchanged pairing file.
2. Create a Shortcut: **Take Screenshot → Send image to Mac (automatic routing)**.
3. Trigger it using your chosen Shortcut entry point, Action Button, or Back Tap.
4. Use the image on your Mac: copy, annotate, crop, redact, extract text, or pin it at its original position and scale.

The sender first tries an authenticated, encrypted nearby connection. If it cannot establish one within approximately three seconds, it can use your configured HTTPS relay. Once direct delivery has started, it does not silently resend over a different route.

For relayed images, encryption and optional lossy compression happen on the phone; only the paired Mac decrypts the image. Binary ciphertext avoids Base64 expansion on the wire. The phone verifies the authenticated save receipt rather than treating an HTTP success alone as proof of delivery.

## Scope and limits

- No cloud account, hosted relay, analytics SDK, or bundled credentials.
- Mac screenshot capture, editing, OCR, clipboard copy, and pinning are included.
- This does not intercept the native iPhone screenshot buttons or suppress system execution indicators.
- USB photo import is a separate legacy feature. A cable does not mean a Shortcut uses USB.
- The receiver must be running and awake. Background delivery, peer-to-peer networking, and latency depend on iOS and the network.
- The legacy HTTP receiver is not E2EE and must not be exposed to the Internet.
- This is not an independently audited cryptographic product. The relay still sees traffic metadata.

## Build

Use Xcode 26+ / Swift 6.2+ and Node.js 22+. The Mac deployment target is macOS 13; the standalone iPhone target is iOS 26. Older Mac versions have not been individually verified.

```sh
swift test
node --test relay/server.test.mjs
python3 scripts/test-public-layout.py
PHONESNAP_ALLOW_ADHOC=1 PHONESNAP_APP_PATH=dist/PhoneSnap.app bash scripts/build-app.sh
```

Open `ios/PhoneSnap.xcodeproj`, select your own signing team and a unique bundle identifier, and build the iPhone target. No signing certificate or developer account is included. The standalone app requires its own pairing; it does not migrate another installed app's private data.

There is no App Store, TestFlight, or notarized universal Mac release. Historical in-device acceptance of the transport module does not establish end-to-end acceptance of this newly extracted standalone app.

See the Chinese [setup guide](docs/SETUP.md) for the complete pairing flow and [relay guide](relay/README.md) for optional self-hosting.

MIT. See [LICENSE](LICENSE), [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md), and [CONTRIBUTING](CONTRIBUTING.md).
