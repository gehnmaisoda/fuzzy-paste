#!/bin/bash
set -euo pipefail

# FuzzyPaste seed script
# デバッグ用テストデータをスニペットとクリップボード履歴に投入する。
# べき等: 同じタイトル/テキストが既に存在する場合はスキップする。

FPASTE=".build/debug/fpaste"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------
# ビルドチェック
# ----------------------------------------------------------------
if [ ! -x "$FPASTE" ]; then
  echo "fpaste が見つかりません。先にビルドしてください: swift build -Xswiftc -DDEV"
  exit 1
fi

# ----------------------------------------------------------------
# べき等チェック用ヘルパー
# ----------------------------------------------------------------
snippet_exists() {
  $FPASTE list --json 2>/dev/null | grep -qF "\"$1\"" && return 0 || return 1
}

add_snippet() {
  local title="$1"; shift
  if snippet_exists "$title"; then
    echo "  skip: $title (exists)"
  else
    $FPASTE add "$title" "$@"
  fi
}

add_history_text() {
  $FPASTE history add "$1"
}

# ----------------------------------------------------------------
# テスト用ファイル生成
# ----------------------------------------------------------------
echo "=== Generating test files ==="

# PNG 画像（Python で最小限の PNG を生成）
python3 -c "
import struct, zlib, sys
def png(w, h, r, g, b):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    raw = b''
    for _ in range(h):
        raw += b'\x00' + bytes([r, g, b]) * w
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
with open(sys.argv[1], 'wb') as f: f.write(png(120, 80, 230, 70, 70))    # red
with open(sys.argv[2], 'wb') as f: f.write(png(200, 60, 70, 130, 230))   # blue
with open(sys.argv[3], 'wb') as f: f.write(png(320, 240, 50, 190, 110))  # green (history)
" "$TMP/red.png" "$TMP/blue.png" "$TMP/green.png"

# CSV
cat > "$TMP/employees.csv" << 'CSV'
name,email,department,role
Tanaka Taro,tanaka@example.com,Engineering,Lead
Suzuki Hanako,suzuki@example.com,Design,Senior
Sato Jiro,sato@example.com,Marketing,Manager
Yamada Yuki,yamada@example.com,Engineering,Junior
Kobayashi Mika,kobayashi@example.com,Sales,Director
CSV

# PDF（最小限の有効な PDF）
cat > "$TMP/spec.pdf" << 'PDF'
%PDF-1.0
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/MediaBox[0 0 595 842]/Parent 2 0 R/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 44>>stream
BT /F1 18 Tf 50 780 Td (FuzzyPaste Spec) Tj ET
endstream
endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
xref
0 6
0000000000 65535 f
0000000009 00000 n
0000000058 00000 n
0000000115 00000 n
0000000266 00000 n
0000000360 00000 n
trailer<</Size 6/Root 1 0 R>>
startxref
425
%%EOF
PDF

# JSON
cat > "$TMP/config.json" << 'JSON'
{
  "app": "FuzzyPaste",
  "version": "1.0.0",
  "settings": {
    "maxHistory": 500,
    "theme": "dark",
    "hotkey": "Cmd+Shift+V",
    "fuzzyThreshold": 0.6
  },
  "features": ["clipboard", "snippets", "fuzzy-search"]
}
JSON

echo "  created: red.png, blue.png, green.png, employees.csv, spec.pdf, config.json"

# ----------------------------------------------------------------
# スニペット投入
# ----------------------------------------------------------------
echo ""
echo "=== Adding snippets ==="

# テキスト（プレースホルダーなし）
add_snippet "お疲れ様テンプレ" \
  "$(printf 'お疲れ様です。\n\n表題の件について、ご確認をお願いいたします。\nお忙しいところ恐縮ですが、ご対応いただけますと幸いです。\n\nよろしくお願いいたします。')" \
  --tag seed --tag メール --tag 定型文

# テキスト（{{}} プレースホルダーあり）
add_snippet "面談日程メール" \
  "$(printf '{{name}}様\n\nお世話になっております。\n{{date}}の面談について、下記の通りご案内いたします。\n\n当日はどうぞよろしくお願いいたします。')" \
  --tag seed --tag メール --tag テンプレ

# 画像（originalFileName あり = ファイルパス指定）
add_snippet "テスト画像（赤）" \
  --image "$TMP/red.png" \
  --tag seed --tag テスト --tag 画像

# 画像（originalFileName あり = 別のファイル）
add_snippet "テスト画像（青）" \
  --image "$TMP/blue.png" \
  --tag seed --tag テスト --tag 画像

# CSV
add_snippet "社員リスト" \
  --file "$TMP/employees.csv" \
  --tag seed --tag データ --tag CSV

# PDF
add_snippet "仕様書" \
  --file "$TMP/spec.pdf" \
  --tag seed --tag ドキュメント --tag PDF

# JSON
add_snippet "アプリ設定" \
  --file "$TMP/config.json" \
  --tag seed --tag 設定 --tag JSON

# ----------------------------------------------------------------
# クリップボード履歴投入
# ----------------------------------------------------------------
echo ""
echo "=== Adding history ==="

# テキスト（プレーン）
add_history_text "$(printf 'お疲れ様です。\n先日の件、確認が取れましたのでご連絡いたします。')"

# テキスト（{{}} 付き — 履歴にもテンプレ的なテキストが残るケース）
add_history_text "$(printf '{{customer_name}} 様\n\nご注文番号: {{order_id}}\n発送予定日: {{ship_date}}\n\n何かご不明な点がございましたらお問い合わせください。')"

# 画像 x2
$FPASTE history add --image "$TMP/red.png"
$FPASTE history add --image "$TMP/green.png"

# CSV
$FPASTE history add --file "$TMP/employees.csv"

# PDF
$FPASTE history add --file "$TMP/spec.pdf"

# JSON
$FPASTE history add --file "$TMP/config.json"

echo ""
echo "=== Done ==="
$FPASTE list 2>&1 | grep -c "seed" | xargs -I{} echo "Seed snippets: {} items"
$FPASTE history list 2>&1 | wc -l | xargs -I{} echo "History: {} items"
