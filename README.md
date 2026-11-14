# 旅ベース（通知の事前検証版）

iPhone・Android で Web Push 通知が届くかを確かめるための最小限の PWA です。
旅程管理の機能はまだ入っていません（通知の検証が終わってから 1 機能ずつ追加します）。

公開先（予定）: https://konkora780-ux.github.io/tabi-base/

## ファイル構成

| ファイル | 役割 |
|---|---|
| `index.html` | 検証画面（ログイン・通知許可・テスト送信・記録表示） |
| `sw.js` | Service Worker。アプリを閉じていても通知を受け取り、タップで画面を開く |
| `manifest.webmanifest`, `icons/` | ホーム画面に追加するための情報とアイコン |
| `lib/supabase-2.117.3.js` | Supabase の公式ライブラリ（オフラインでも動くよう同梱） |
| `supabase/setup.sql` | 表・RLS・Cron の設定（SQL Editor で実行） |
| `supabase/functions/tabi-push/` | 通知を送るサーバー側プログラム |
| `.github/workflows/deploy-push-function.yml` | 上のプログラムを Supabase へ反映する仕組み |

## Supabase について

- 既存の無料プロジェクト「drops」を共用します。ほかのアプリと混ざらないよう、
  旅ベースの表・関数はすべて `tabi_` で始まる名前にしています。
- 秘密鍵（VAPID 秘密鍵・service_role キー）はリポジトリに置きません。
  HTML に書くのは公開して問題ない「anon（publishable）キー」だけです。

## 通知の仕組み（概要）

1. 端末が通知を許可すると、端末の宛先情報を `tabi_push_subscriptions` に登録。
2. 通知の予定を `tabi_notifications` に保存。
3. Cron（毎分）または「今すぐ送る」で `tabi-push` が端末ごとに送信し、
   結果を `tabi_notification_deliveries` に記録。
   - 受付（accepted）… プッシュサービスが預かった段階。端末に届いたとは限らない
   - 受信（received_at）… 端末の Service Worker から「受け取った」報告があった
   - タップ（clicked_at）… 通知がタップされた
4. 一時的な失敗は、失敗した端末だけ 1 分後・5 分後に再試行（最大 3 回）。
   宛先が無効（404/410）なら再試行せず端末を無効化。
5. 重複の抑制: 通知×端末の組み合わせはデータベースで 1 件に限定し、送信の取り出しは
   同時に動いても二重に取らない仕組み（SKIP LOCKED）にしています。端末側でも同じ通知は
   1 つにまとめて表示します（tag）。
6. 予定変更時は同じ名前（dedupe_key）の古い予約を自動で取り消します。
