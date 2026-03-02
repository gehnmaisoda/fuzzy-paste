# FuzzyPaste 開発進捗

## ステータス凡例

- [ ] 未着手
- [~] 進行中
- [x] 完了

## プロジェクト初期化

- [x] Swift Package Manager セットアップ (`Package.swift`)
- [x] ディレクトリ構成作成
- [x] Makefile 作成 (build / run / bundle / clean)
- [x] Info.plist 作成 (LSUIElement=true)
- [x] エントリーポイント (`main.swift`)
- [x] AppDelegate 最小実装 (メニューバーアイコン表示)
- [x] .gitignore
- [x] README.md
- [x] PROGRESS.md

## コア機能

- [x] ClipboardMonitor — NSPasteboardポーリング (0.5秒間隔)、変更検知
- [x] HistoryStore — 履歴の永続化 (JSON、最大500件、FIFO)
- [x] FuzzyMatcher — fuzzy searchアルゴリズム
- [x] PasteHelper — 選択アイテムのペースト実行

## UI

- [x] SearchWindow — ポップアップ検索ウィンドウ (テキスト入力 + リスト表示)
- [x] HotkeyManager — グローバルホットキー登録 (Cmd+Shift+V)
- [x] カーソル位置基準のウィンドウ表示
- [x] フロストガラス風デザイン (NSVisualEffectView)
- [x] ヒントバー (⏎ Paste / ⌘C Copy / esc Close)
- [x] Enter でペースト、Cmd+C でコピーのみ
- [x] フォーカス離脱時にウィンドウ自動閉じ
- [x] コードレビュー＆リファクタリング (92点)
- [x] 全ソースファイルへのコメント追加

## 追加機能

- [x] SnippetStore — スニペット管理（登録・編集・削除 + 検索結果に混合表示）
- [x] 画像クリップボード対応（画像コピーの履歴保存・プレビュー表示）
- [x] Quick Look プレビュー（Shift+Space でアイテムの詳細プレビュー）
- [x] 除外アプリ設定（パスワードマネージャー等からのコピーを履歴に保存しない）
- [x] 設定ウィンドウ（SwiftUI + NSHostingView、サイドバー + コンテンツ）
- [x] スニペットタグ機能（タグ付け・タグ絞り込み検索）
- [x] D&D（外部アプリへのドラッグ&ドロップ）
- [x] マルチセレクト（Shift/Cmd+Click で複数選択、選択順バッジ、結合ペースト）
- [x] 任意ファイルのクリップボード履歴対応（PDF, CSV, ZIP等のファイルコピー検知・保存・ペースト・D&D・検索）
- [x] ウィンドウサイズ設定（小・中・大の3段階、サムネ・行高さ連動）
- [ ] ショートカットキー設定（起動ホットキーのカスタマイズ）
- [ ] 自動起動 (SMAppService)
- [ ] アクセシビリティ権限チェック・リクエスト

## 配布

- [ ] リリースビルド最適化
- [ ] DMG / zip パッケージング
- [ ] GitHub Releases 設定
