# paintauri

A pixel-perfect Paint clone for macOS, built with Tauri.

Classic Windows Paint has no macOS equivalent. `paintauri` reproduces the
classic toolset — pencil, brush, bucket fill, eraser, shapes, selection,
color picker, text — with **dot-exact editing**: every stroke edits raw
pixels with no anti-aliasing, and zoom uses nearest-neighbor scaling so
pixel art never blurs.

## Status

Early development. Not yet usable.

## Tech stack

- Frontend: Vite + TypeScript, Canvas 2D (`image-rendering: pixelated`)
- Desktop shell: Tauri v2
- Primary target: macOS

## Local dev

```bash
cd frontend && npm install
npm run dev
npm run tauri:dev
```

## License

MIT
