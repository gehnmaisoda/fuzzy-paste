# FuzzyPaste - Claude Code 開発ガイド

## プロジェクト概要

macOSネイティブのクリップボードマネージャー。Clipyの改善版で、fuzzy searchによるインクリメンタル検索が最大の特徴。

## ビルド・実行コマンド

- `make run` — デバッグビルド & 実行
- `make release` — リリースビルド
- `make bundle` — .appバンドル作成
- `make clean` — クリーン
- `swift build` — ビルドのみ

## 技術スタック

- Swift / AppKit / Swift Package Manager
- Xcode IDEは使わない (エディタ + ターミナル)
- 対象: macOS 13+

## コーディング規約

- Swift 6.1 の concurrency モデルに従う (`@MainActor` など)
- AppKit ベース。UIKit は使わない
- SwiftUI は部分的に利用可 (NSHostingView 経由)

## 進捗管理

- **PROGRESS.md を常に最新の状態に保つこと**
- 機能の実装を開始したら、該当項目を `[~]` (進行中) に更新する
- 機能の実装が完了したら、該当項目を `[x]` (完了) に更新する
- 新しいタスクが発生したら PROGRESS.md に追記する
- 作業の開始時と終了時に PROGRESS.md を確認・更新する
