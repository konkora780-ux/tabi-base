// 旅ベース 通知送信プログラム（Supabase Edge Function: tabi-push）
//
// できること（action で切り替え）
//   vapid-key : 通知の公開鍵を返す（だれでも可。秘密ではない）
//   send-now  : ログイン中の本人に今すぐテスト通知を送る
//   dispatch  : 時刻になった通知・再試行分を送る（Cron 専用。合言葉が必要）
//   receipt   : 端末からの「受信した」「タップした」報告を記録する
//
// 必要な秘密情報（Supabase の Edge Function Secrets に登録。リポジトリには置かない）
//   VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_SUBJECT
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY は Supabase が自動で用意する

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.117.3";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "https://konkora780-ux.github.io/tabi-base/";

// 再試行の間隔（設計書：1分後・5分後・15分後、最大3回。有効期限を過ぎたら打ち切り）
const RETRY_DELAYS_MIN = [1, 5, 15];
const MAX_ATTEMPTS = RETRY_DELAYS_MIN.length + 1;
// 有効期限のない通知（テスト通知）の保管時間
const DEFAULT_TTL_SECONDS = 60 * 60;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" },
  });
}

type Claimed = {
  delivery_id: string; receipt_token: string; attempts: number;
  notification_id: string; title: string; body: string; url: string; debug_fail_first: boolean;
  subscription_id: string; endpoint: string; p256dh: string; auth: string;
  expires_at: string | null; urgency: string | null; trip_id: string | null; kind: string | null;
};

// 失敗の種類を判断する
//   gone  : 端末の登録が無効（アンインストール等）→ 再試行しない・端末を無効化
//   retry : 一時的な失敗（混雑・通信エラー）→ 時間をおいて再試行
//   failed: 設定などの失敗 → 再試行しても直らないので打ち切り
function classify(status: number | null): "gone" | "retry" | "failed" {
  if (status === 404 || status === 410) return "gone";
  if (status === null || status === 429 || status >= 500) return "retry";
  return "failed";
}

async function sendOne(c: Claimed) {
  const receiptUrl = `${SUPABASE_URL}/functions/v1/tabi-push`;
  const payload = JSON.stringify({
    title: c.title,
    body: c.body,
    url: c.url,
    trip: c.trip_id, // タップしたときに開く旅（見つからなければホームで案内）
    kind: c.kind,
    tag: c.notification_id, // 同じ通知は端末上で1つにまとまる（二重表示の抑制）
    nid: c.notification_id,
    d: c.delivery_id,
    t: c.receipt_token,
    r: receiptUrl,
  });

  let httpStatus: number | null = null;
  let error = "";
  let ok = false;
  // TTL（端末が圏外のとき、プッシュサービスが保管する時間）は有効期限までの残り時間にする
  const ttl = c.expires_at
    ? Math.floor((new Date(c.expires_at).getTime() - Date.now()) / 1000)
    : DEFAULT_TTL_SECONDS;
  if (ttl <= 0) {
    await admin.from("tabi_notification_deliveries").update({ status: "expired", last_error: "有効期限を過ぎたため送りませんでした" })
      .eq("id", c.delivery_id);
    return { id: c.delivery_id, result: "expired", httpStatus: null };
  }

  if (c.debug_fail_first && c.attempts === 1) {
    // 再試行テスト用：1回目だけ送らずに「一時的な失敗」として扱う
    httpStatus = 503;
    error = "テスト用にわざと失敗させました（1回目）";
  } else {
    try {
      const res = await webpush.sendNotification(
        { endpoint: c.endpoint, keys: { p256dh: c.p256dh, auth: c.auth } },
        payload,
        { TTL: ttl, urgency: c.urgency === "normal" ? "normal" : "high", topic: c.notification_id.replaceAll("-", "").slice(0, 32) },
      );
      httpStatus = res.statusCode;
      ok = true;
    } catch (e) {
      const err = e as { statusCode?: number; body?: string; message?: string };
      httpStatus = err.statusCode ?? null;
      error = (err.body || err.message || String(e)).slice(0, 500);
    }
  }

  const now = new Date();
  if (ok) {
    await admin.from("tabi_notification_deliveries").update({
      status: "accepted", http_status: httpStatus, accepted_at: now.toISOString(), last_error: null,
    }).eq("id", c.delivery_id);
    await admin.from("tabi_push_subscriptions").update({
      last_success_at: now.toISOString(), failure_count: 0,
    }).eq("id", c.subscription_id);
    return { id: c.delivery_id, result: "accepted", httpStatus };
  }

  let kind = classify(httpStatus);
  if (kind === "retry" && c.attempts >= MAX_ATTEMPTS) kind = "failed";
  const update: Record<string, unknown> = { status: kind, http_status: httpStatus, last_error: error };
  if (kind === "retry") {
    const delay = RETRY_DELAYS_MIN[c.attempts - 1] ?? RETRY_DELAYS_MIN[RETRY_DELAYS_MIN.length - 1];
    const next = new Date(now.getTime() + delay * 60_000);
    if (c.expires_at && next >= new Date(c.expires_at)) {
      update.status = "expired"; // 次の再試行が有効期限より後になるので、ここで打ち切る
    } else {
      update.next_attempt_at = next.toISOString();
    }
  }
  await admin.from("tabi_notification_deliveries").update(update).eq("id", c.delivery_id);

  const subUpdate: Record<string, unknown> = { last_failure_at: now.toISOString() };
  if (kind === "gone") subUpdate.is_active = false;
  await admin.from("tabi_push_subscriptions").update(subUpdate).eq("id", c.subscription_id);
  await admin.rpc("tabi_increment_failure", { p_subscription: c.subscription_id });
  return { id: c.delivery_id, result: kind, httpStatus, error };
}

async function dispatch(notificationId: string | null = null) {
  if (!VAPID_PUBLIC || !VAPID_PRIVATE) throw new Error("VAPID鍵が未設定です");
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
  const { data, error } = await admin.rpc("tabi_claim_due_deliveries", {
    p_limit: 50, p_notification: notificationId,
  });
  if (error) throw new Error(error.message);
  const claimed = (data ?? []) as Claimed[];
  const results = await Promise.all(claimed.map(sendOne));
  await admin.rpc("tabi_finish_notifications");
  return results;
}

async function getUser(req: Request) {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) return null;
  return data.user;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POSTのみ" }, 405);

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* 空のまま */ }
  const action = String(body.action ?? "");

  try {
    if (action === "vapid-key") {
      return json({ publicKey: VAPID_PUBLIC });
    }

    if (action === "receipt") {
      const kind = body.kind === "clicked" ? "clicked" : "received";
      const { data, error } = await admin.rpc("tabi_record_receipt", {
        p_delivery: String(body.d ?? ""), p_token: String(body.t ?? ""), p_kind: kind,
      });
      if (error) return json({ ok: false }, 400);
      return json({ ok: data === true });
    }

    if (action === "dispatch") {
      const secret = req.headers.get("x-cron-secret") ?? "";
      const { data: valid } = await admin.rpc("tabi_check_cron_secret", { p_secret: secret });
      if (valid !== true) return json({ error: "合言葉が違います" }, 401);
      const results = await dispatch();
      return json({ sent: results.length, results });
    }

    if (action === "send-now") {
      const user = await getUser(req);
      if (!user) return json({ error: "ログインが必要です" }, 401);
      const { data: n, error } = await admin.from("tabi_notifications").insert({
        user_id: user.id,
        title: String(body.title ?? "旅ベース テスト通知").slice(0, 100),
        body: String(body.body ?? "").slice(0, 300),
        url: "./?from=push",
        send_at: new Date().toISOString(),
        debug_fail_first: body.simulateFailure === true,
      }).select("id").single();
      if (error) throw new Error(error.message);
      const results = await dispatch(n.id);
      return json({ notificationId: n.id, results });
    }

    // 二重送信テスト：同じ通知の送信処理を同時に2回動かしても、送られるのは端末ごとに1回だけか確認する
    if (action === "double-dispatch-test") {
      const user = await getUser(req);
      if (!user) return json({ error: "ログインが必要です" }, 401);
      const { data: n, error } = await admin.from("tabi_notifications").insert({
        user_id: user.id, title: "二重送信テスト", body: "この通知は1回だけ表示されれば正常です",
        url: "./?from=push", send_at: new Date().toISOString(),
      }).select("id").single();
      if (error) throw new Error(error.message);
      const [a, b] = await Promise.all([dispatch(n.id), dispatch(n.id)]);
      return json({ notificationId: n.id, firstRun: a.length, secondRun: b.length });
    }

    return json({ error: "不明な操作です" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message }, 500);
  }
});
