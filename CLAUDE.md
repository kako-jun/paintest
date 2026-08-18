# paintauri — 開発ガイド

## コンセプト

Windows 11 の Paint 相当をmacOSで動かす。UIの見た目の忠実さより、**ドット単位でぼけない編集**を最優先する。

- 全ツール（鉛筆・ブラシ・バケツ・消しゴム・図形・選択・スポイト・テキスト）はアンチエイリアスなしでピクセルを直接編集する
- ズームはニアレストネイバー（`image-rendering: pixelated`）。拡大してもドットが滲まない
- レイヤー・AI背景除去などWindows11 Paintの最新機能は対象外（クラシックPaint相当のスコープ）

## 技術スタック

- **フロントエンド**: Vite + TypeScript（`frontend/`）、描画は Canvas 2D
- **desktop shell**: Tauri v2（`src-tauri/`）
- **第一対応 OS**: macOS
- **保存形式**: PNG（将来的にBMP検討）

## ローカル起動

```bash
cd frontend && npm install
npm run dev
npm run tauri:dev
```

## 実装方針

- キャンバスの内部解像度とCSS表示サイズを分離し、拡大縮小は常に整数倍のニアレストネイバーで行う
- ブラシ描画も含め、`ctx.imageSmoothingEnabled = false` を徹底し、サブピクセル座標に丸め誤差でアンチエイリアスがかかる経路を作らない
- Windows Paintのツールバー構成・アイコン配置に寄せるが、ピクセル寸法まで一致させることは目的にしない

## リポジトリ方針

- `README.md` はエンドユーザー向け。実装・設計判断は `docs/` とこのファイルに書く
- `backend/` は置かず、`frontend/ + src-tauri/` 構成にする

## 禁止事項

- Co-Authored-By をコミットメッセージに付けない
- ブラシ・図形描画にアンチエイリアス/ぼかしを混ぜない
