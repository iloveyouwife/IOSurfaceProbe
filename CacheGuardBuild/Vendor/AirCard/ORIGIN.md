# Binary provenance

- Origin: https://github.com/LinkPass888/AirBeep, bundled `Vendor/AirCard/AirliftFFI.xcframework`
- Referenced revision: `0052ecbc961ba1965587839bda388150027a5cc4`
- iOS arm64 static library SHA-256: `1ec4b02710aedab8215a7d41bb70ff54d1de80e5c63d594cf8cd98f34a59808c`
- License: MIT (`LICENSE` in this directory), copyright 2026 Johnny Franks.
- The Swift pairing implementation in CacheGuard is separate project code; AirBeep's GPLv3 Swift sources are not bundled.

The XCFramework includes arm64 device and arm64 simulator slices. Always verify
the framework API and license again before replacing it with a newer version.
