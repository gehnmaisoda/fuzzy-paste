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

## アプリの起動・停止

- `make run` や `pkill` などのプロセス管理はユーザーが行う。ユーザーからの指示がない限り Claude は実行しない。

## タスク管理

- **GitHub Issues で管理する**（`gh issue list` / `gh issue create` 等を活用）
- 新しいタスクやバグを発見したら `gh issue create` で issue を作成する
- 作業開始時に関連 issue を確認し、完了したら close する
