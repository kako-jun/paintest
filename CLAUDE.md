# paintest — 開発ガイド

## コンセプト

Windows 11 の Paint 相当をmacOSでネイティブに動かす。UIの見た目の忠実さより、**ドット単位でぼけない編集**を最優先する。

- 全ツール（鉛筆・ブラシ・バケツ・消しゴム・図形・選択・スポイト・テキスト）はアンチエイリアスなしでピクセルを直接編集する
- ズームは常にニアレストネイバー（`CGContext.interpolationQuality = .none`）。拡大してもドットが滲まない
- レイヤー・AI背景除去などWindows11 Paintの最新機能は対象外（クラシックPaint相当のスコープ）
- Web wrapper（Tauri/Electron等）ではなく、Swift/AppKitによる純粋なmacOSネイティブアプリとする

## 技術スタック

- **言語**: Swift
- **UI**: AppKit（`NSWindow` / `NSView`ベース。SwiftUIは補助的に検討可）
- **描画**: Core Graphics（`CGContext`）
- **第一対応 OS**: macOS
- **保存形式**: PNG（将来的にBMP検討）

## ローカル起動

```bash
swift build
swift run
```

## テスト

```bash
swift test
```

ロジック本体は`paintestCore`（ライブラリターゲット）に置き、`paintest`（実行ターゲット）は起動のみを担う。XCTestが実行ターゲットを直接importできないための分割。UI依存（`NSAlert.runModal`・`NSEvent`・実描画）で単体テスト不可能な部分は無理にテスト化せず、実機確認に委ねる。

## 実装方針

- キャンバスの内部解像度（ピクセルグリッド）とビュー表示サイズを分離し、拡大縮小は常に整数倍・ニアレストネイバーで行う
- `CGContext.interpolationQuality = .none` を全描画パスで徹底し、サブピクセル座標の丸め誤差でアンチエイリアスがかかる経路を作らない
- Windows Paintのツールバー構成・アイコン配置に寄せるが、ピクセル寸法まで一致させることは目的にしない

## リポジトリ方針

- `README.md` はエンドユーザー向け。実装・設計判断は `docs/` とこのファイルに書く
- `backend/`相当は置かず、Swift Package標準構成にする（`paintestCore`ライブラリ + `paintest`実行 + `paintestCoreTests`テストの3ターゲット）

## 禁止事項

- Co-Authored-By をコミットメッセージに付けない
- ブラシ・図形描画にアンチエイリアス/ぼかしを混ぜない
- Tauri/Electron等のWeb wrapperに戻さない（ネイティブ方針で確定済み）
