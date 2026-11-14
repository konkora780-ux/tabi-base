# 旅ベース 通知テスト 設定と実機テストの手順

## A. 初回の設定（こんちゃんの操作が必要な部分）

### A-1. GitHub にリポジトリを作る（済んだら Claude に連絡）
1. https://github.com/new を開く
2. Repository name: `tabi-base`、**Public** を選んで「Create repository」

### A-2. Supabase の anon（公開用）キーを Claude に伝える
このキーは公開しても安全な値で、アプリの HTML に入れて使います（RLS で守られるため）。
1. https://supabase.com/dashboard で「drops」を開く
2. 左下の歯車「Project Settings」→「API Keys」
3. 「anon public」（または「Publishable key」`sb_publishable_…`）の値をコピーして Claude に送る
   - **「service_role」や「Secret key」は絶対に送らないでください**（こちらは秘密鍵です）

### A-3. データベースの設定（SQL を 1 回実行）
1. drops の左メニュー「SQL Editor」→「New query」
2. `supabase/setup.sql` の中身を全部貼り付けて「Run」
3. 「Success. No rows returned」または表が出れば成功
   - 既存の drops の表は変更しません。`tabi_` で始まる表・関数と、Cron ジョブ 2 つが追加されます。

### A-4. ログイン用メールに「数字のコード」を載せる（GmailのSMTPを使う）
Supabase標準のメール送信ではテンプレートを編集できず、送信数も1時間にごくわずかなため、ご自分のGmailから送る設定にします（無料）。
1. Googleアカウント（https://myaccount.google.com/security）で「2段階認証プロセス」をオンにする
2. https://myaccount.google.com/apppasswords でアプリ名「Supabase」と入れて作成 → 表示された16文字をコピー（この画面を閉じると二度と見られません）
3. Supabase の drops →「Authentication」→「Emails」→「SMTP Settings」→ Enable Custom SMTP をオン
   - Sender email: ご自分のGmailアドレス／Sender name: 旅ベース
   - Host: `smtp.gmail.com`／Port: `465`
   - Username: ご自分のGmailアドレス／Password: 2でコピーした16文字
   - 「Save」
4. 「Authentication」→「Rate Limits」で「emails per hour」を `30` 程度にして保存
5. 「Emails」→「Templates」→「Magic link or OTP」の本文に次の1行を足して保存
   `<p>確認コード：<b>{{ .Token }}</b></p>`
   - ⚠ drops を使う他のアプリのログインメールも、送信元がこのGmailになり、コードの行が表示されます（リンクは残ります）。
   - アプリパスワードは秘密情報です。Claude やチャットには送らないでください。

### A-5. 送信プログラムを Supabase に載せる
1. Supabase のアカウント設定 → Access Tokens（https://supabase.com/dashboard/account/tokens）で「Generate new token」→ 名前は `tabi-base` → コピー
2. GitHub の tabi-base →「Settings」→「Secrets and variables」→「Actions」→「New repository secret」
   - Name: `SUPABASE_ACCESS_TOKEN`／Secret: さきほどのトークン
3. 「Actions」タブ →「通知送信プログラムをSupabaseへ反映」→「Run workflow」
4. 緑のチェックになれば成功（初回は通知用の鍵も自動で作ります）

## B. 実機テスト（iPhone と Android それぞれ）

結果は「○／×／気づいたこと」で Claude に送ってください。届くまでの時間もわかれば書いてください。

| # | 確かめること | やり方 | 期待する結果 |
|---|---|---|---|
| 1 | ホーム画面に追加 | iPhone: Safari で開く→共有→「ホーム画面に追加」／Android: Chrome のメニュー→「ホーム画面に追加」または「アプリをインストール」 | 「旅ベース」アイコンができ、開くと「ホーム画面から起動：はい」 |
| 10 | メールのコードでログイン（iPhoneはホーム画面のアプリで） | ②でメールアドレス入力→コードを受け取る→数字を入力 | 「ログイン中」になる。アプリを閉じて開き直してもログインのまま |
| 2 | 通知の許可 | ③のボタン→許可 | 「通知の許可：許可済み」、登録済みの端末に表示 |
| 6 | Supabase からテスト通知 | ④「今すぐ送る」 | 通知が表示され、⑤で「受付」「受信」になる |
| 3 | アプリを閉じた状態 | 「今すぐ送る」直後にアプリを上にスワイプして完全に閉じる | 通知が届く |
| 4 | 画面ロック中 | 「今すぐ送る」直後に電源ボタンでロック | ロック画面に通知が出る |
| 5 | タップで開く | 届いた通知をタップ | アプリが開き「通知をタップしてアプリが開きました」と表示、⑤に「タップ」 |
| 7 | 指定時刻に Cron で送信 | ④で 3 分後の時刻に予約→アプリを閉じて待つ | 予約時刻から 1 分程度で届く |
| 7' | 予定変更で古い通知を取り消し | 予約したあと「予約を2分後に変更」 | 古い予約は「取り消し」になり、変更後の 1 件だけ届く |
| 8 | 記録 | ⑤「記録を更新」 | 受付・受信・タップ・失敗が表示される |
| 9a | 再試行 | ④「再試行テスト」→アプリを閉じて 1〜2 分待つ | 1 回目は「再試行待ち」、約 1 分後に届き「送信2回・受付・受信」 |
| 9b | 重複抑制 | ④「二重送信テスト」 | 通知は 1 つだけ。メッセージの件数が端末台数と同じ |

### 補足
- 「受付」はプッシュの配達業者（Apple／Google）が預かった段階です。端末に届いたかは「受信」で判断します。
- 圏外や省電力モードでは、受信の報告が遅れたり届かなかったりします。届いたのに「受信」が付かない場合も記録してください。
- iPhone は iOS 16.4 以降が必要です。設定→一般→情報 でバージョンを確認できます。
