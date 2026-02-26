# FuzzyPaste

macOSネイティブのクリップボードマネージャー。[Clipy](https://github.com/Clipy/Clipy)の改善版として、**fuzzy searchによるインクリメンタル検索**を最大の特徴とする。

## 特徴

- **fuzzy search** — インクリメンタルにクリップボード履歴を絞り込み
- **メニューバー常駐** — Dockに表示せず、メニューバーアイコンのみで動作
- **グローバルホットキー** — `Cmd+Shift+V` で検索UIをポップアップ表示
- **お気に入り** — よく使うテキストをスター付きで永続保存
- **自動起動** — ログイン時に自動起動

## 技術スタック

| 項目 | 内容 |
|---|---|
| 言語 | Swift |
| フレームワーク | AppKit (UIはSwiftUIも部分的に利用可) |
| ビルド | Swift Package Manager (`swift build`) |
| 対象OS | macOS 13+ |

Xcode IDEは使わず、任意のエディタ + ターミナルで開発。

## 必要環境

- macOS 13 (Ventura) 以降
- Xcode Command Line Tools (Swiftコンパイラ + macOS SDK)

## ビルド・実行

```sh
# デバッグビルド & 実行
make run

# リリースビルド
make release

# .appバンドル作成
make bundle

# クリーン
make clean
```

## アーキテクチャ

```
FuzzyPaste.app
├── AppDelegate          — アプリのライフサイクル管理、メニューバー常駐
├── ClipboardMonitor     — NSPasteboardのポーリング、変更検知
├── HistoryStore         — 履歴の保存/読込/削除 (最大500件)
├── FavoritesStore       — お気に入りの管理
├── FuzzyMatcher         — fuzzy searchアルゴリズム
├── SearchWindow         — ポップアップ検索UI (テキスト入力 + リスト表示)
├── HotkeyManager        — グローバルホットキー登録 (Cmd+Shift+V)
└── PasteHelper          — 選択アイテムのペースト実行
```

## データ保存先

```
~/Library/Application Support/FuzzyPaste/
├── history.json       — クリップボード履歴 (最大500件、FIFO)
└── favorites.json     — お気に入りアイテム (件数制限なし)
```

## 権限

- **アクセシビリティ権限** — グローバルホットキー、ペースト操作に必要
- 初回起動時にユーザーに許可を求めるダイアログを表示

## 配布

- GitHub Releases で .app を zip/DMG として配布
- Homebrew Cask での配布も将来的に対応

## ライセンス

MIT
