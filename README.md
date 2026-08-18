# paintest

A pixel-perfect Paint clone for macOS, built natively with Swift/AppKit.

Classic Windows Paint has no macOS equivalent. `paintest` reproduces the
classic toolset — pencil, brush, bucket fill, eraser, shapes, selection,
color picker, text — with **dot-exact editing**: every stroke edits raw
pixels with no anti-aliasing, and zoom uses nearest-neighbor scaling so
pixel art never blurs.

## Status

Early development. Not yet usable.

## Tech stack

- Language: Swift
- UI: AppKit
- Drawing: Core Graphics (`interpolationQuality = .none`)
- Platform: macOS (native only, no cross-platform wrapper)

## Local dev

```bash
swift build
swift run
```

## License

MIT
