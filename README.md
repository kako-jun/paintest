# paintest

A Paint clone for macOS with Photoshop's everyday power tools, built
natively with Swift/AppKit.

Classic Windows Paint has no macOS equivalent. `paintest` reproduces the
classic toolset — pencil, pen, bucket fill, eraser, shapes, selection,
color picker, text — with **dot-exact editing** for the classic tools:
every pencil stroke edits raw pixels with no anti-aliasing, and zoom uses
nearest-neighbor scaling so pixel art never blurs. On top of that,
`paintest` reproduces the Photoshop features people reach for daily —
layers, tone curves, flexible selection, color correction, and layer
transforms — with a screen layout modeled on Photoshop's own.

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
