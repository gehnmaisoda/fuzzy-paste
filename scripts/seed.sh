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

# CSV（横に長い×縦に長いデータ）
cat > "$TMP/employees.csv" << 'CSV'
id,name,email,department,role,office,phone,hire_date,salary,status,manager,team,skills,notes
1,Tanaka Taro,tanaka@example.com,Engineering,Lead,Tokyo HQ,03-1234-5678,2019-04-01,8500000,Active,Yamamoto Ken,Platform,"Go, Rust, K8s",Tech lead for platform team
2,Suzuki Hanako,suzuki@example.com,Design,Senior,Tokyo HQ,03-2345-6789,2020-06-15,7200000,Active,Ito Megumi,UX,"Figma, Sketch, CSS",Design system owner
3,Sato Jiro,sato@example.com,Marketing,Manager,Osaka,06-3456-7890,2018-01-10,7800000,Active,Watanabe Ryo,Growth,"Analytics, SQL, Ads",Leads APAC campaigns
4,Yamada Yuki,yamada@example.com,Engineering,Junior,Tokyo HQ,03-4567-8901,2023-04-01,5000000,Active,Tanaka Taro,Platform,"Python, Docker",New grad 2023
5,Kobayashi Mika,kobayashi@example.com,Sales,Director,Osaka,06-5678-9012,2016-09-01,9500000,Active,,Enterprise,"Negotiation, CRM",Manages enterprise accounts
6,Watanabe Ryo,watanabe@example.com,Marketing,VP,Tokyo HQ,03-6789-0123,2015-03-01,11000000,Active,,Marketing,"Strategy, Branding",VP of Marketing
7,Ito Megumi,ito@example.com,Design,Manager,Tokyo HQ,03-7890-1234,2017-08-20,8000000,Active,Watanabe Ryo,UX,"Research, Prototyping",Design team lead
8,Nakamura Sota,nakamura@example.com,Engineering,Senior,Fukuoka,092-8901-2345,2019-10-01,7500000,Active,Tanaka Taro,Backend,"Java, Spring, AWS",Backend architect
9,Matsumoto Aoi,matsumoto@example.com,HR,Manager,Tokyo HQ,03-9012-3456,2018-05-15,7000000,Active,,People,"Recruiting, D&I",HR business partner
10,Kato Ren,kato@example.com,Engineering,Mid,Tokyo HQ,03-0123-4567,2021-07-01,6200000,Active,Tanaka Taro,Frontend,"React, TypeScript, Next.js",Frontend specialist
11,Yoshida Mai,yoshida@example.com,Finance,Senior,Tokyo HQ,03-1111-2222,2017-04-01,7800000,Active,,Accounting,"Excel, SAP, IFRS",Quarterly reporting lead
12,Morita Kenji,morita@example.com,Engineering,Senior,Remote,080-3333-4444,2020-01-15,7600000,Active,Tanaka Taro,SRE,"Terraform, Prometheus, Linux",On-call rotation lead
13,Fujita Sakura,fujita@example.com,Sales,Mid,Nagoya,052-5555-6666,2022-03-01,5800000,Active,Kobayashi Mika,SMB,"Salesforce, Cold call",Top performer Q3
14,Ogawa Takumi,ogawa@example.com,Engineering,Mid,Tokyo HQ,03-7777-8888,2022-09-01,6000000,Active,Nakamura Sota,Backend,"Go, PostgreSQL, gRPC",API team
15,Hasegawa Yui,hasegawa@example.com,Design,Junior,Fukuoka,092-9999-0000,2024-04-01,4500000,Active,Ito Megumi,UX,"Figma, Illustration",New grad 2024
16,Shimizu Daiki,shimizu@example.com,Engineering,Lead,Remote,080-1212-3434,2018-06-01,8800000,Active,Yamamoto Ken,Mobile,"Swift, Kotlin, Flutter",Mobile team lead
17,Kimura Hana,kimura@example.com,Marketing,Mid,Tokyo HQ,03-5656-7878,2021-11-01,5500000,Active,Sato Jiro,Content,"SEO, Writing, Analytics",Blog & social media
18,Hayashi Ryota,hayashi@example.com,Engineering,Senior,Tokyo HQ,03-9090-1212,2019-02-01,7400000,Active,Shimizu Daiki,Mobile,"Swift, UIKit, CoreData",iOS lead developer
19,Inoue Misaki,inoue@example.com,CS,Manager,Osaka,06-3434-5656,2017-12-01,7200000,Active,,Support,"Zendesk, SQL, Empathy",Customer success lead
20,Mori Kaito,mori@example.com,Engineering,Intern,Tokyo HQ,03-7878-9090,2025-06-01,3600000,Active,Kato Ren,Frontend,"HTML, CSS, JavaScript",Summer intern 2025
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

# レビュー & PR作成
add_snippet "review & create PR" \
  "$(printf '下記の観点を用いた再起的な自己レビュー・修正を行ってください。\n下記に含まれない観点でも気づいた点があれば積極的にレビューしてください。\n- レビュー観点の例\n  - ビジネスロジックが正しいか？\n  - 実装が必要以上に複雑になりすぎてないか？よりシンプルな実装はないか？\n  - 重要な処理, 複雑な処理はコメントで分かりやすく説明されているか？\n  - より可読性の高い書き方はないか？\n  - 本来のスコープをはみ出していないか？\n  - 定数化やDRYできるところはないか？\n  - linter/formatter/型チェック等の基本的な品質基準を満たしているか？\n  - 不要な処理が含まれていないか？\n  - 重たいクエリがないか？\n\nレビューと修正を繰り返し総合的に95点を超えたらPRを作成して下さい！')" \
  --tag seed --tag PR --tag review

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
