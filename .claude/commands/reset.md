以下のステップを順番に実行してください:

1. **mainブランチに切り替えて最新化**
   - `git checkout main && git pull` を実行
   - 未コミットの変更がある場合は AskUserQuestion で差分を提示し、続行するか確認する

2. **GitHub Issues を確認**
   - `gh issue list --state open` でオープンな issue を一覧表示

3. **次にやることを提案**
   - issue の内容・優先度を考慮して、次に取り組むべきタスクを提案
   - 「どれに取り掛かりますか？」と聞いて選択を待つ
