# DAMT RENTAL — Server-side setup (do this once)

Two things must run on a server, not in the browser: sending the Telegram OTP
(needs your bot token secret) and confirming Razorpay payments (a browser
can't be trusted to say "yes I paid"). Supabase Edge Functions handle both for free.

## Prerequisites
```
npm install -g supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF
```

## 1. Store your secrets (never in the HTML file)
```
supabase secrets set TELEGRAM_BOT_TOKEN=8541194519:AAEGla0MYMHD5IaPEEdXINGGDj03EdK9maY
supabase secrets set TELEGRAM_ADMIN_CHAT_ID=8524455420
supabase secrets set RAZORPAY_KEY_SECRET=your_razorpay_key_secret
```
⚠️ Since that bot token was pasted in this chat, treat it as already exposed —
regenerate a fresh token with @BotFather before going live, and use the new one here.

## 2. `supabase/functions/send-otp/index.ts`
```ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  const { user_id, telegram_chat_id } = await req.json();
  const otp = Math.floor(100000 + Math.random() * 900000).toString();

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // hash the OTP before storing (never store it in plaintext)
  const otpHash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(otp));
  const hashHex = Array.from(new Uint8Array(otpHash)).map(b => b.toString(16).padStart(2,"0")).join("");

  await supabase.from("otp_verifications").insert({
    user_id, otp_hash: hashHex,
    expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString()
  });

  const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
  await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      chat_id: telegram_chat_id,
      text: `Your DAMT RENTAL access code is: ${otp}\nValid for 5 minutes.`
    })
  });

  return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" }});
});
```
Deploy: `supabase functions deploy send-otp`

## 3. `supabase/functions/verify-otp/index.ts`
```ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  const { user_id, otp } = await req.json();
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const otpHash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(otp));
  const hashHex = Array.from(new Uint8Array(otpHash)).map(b => b.toString(16).padStart(2,"0")).join("");

  const { data } = await supabase.from("otp_verifications")
    .select("*").eq("user_id", user_id).eq("otp_hash", hashHex)
    .eq("verified", false).gt("expires_at", new Date().toISOString())
    .order("created_at", { ascending: false }).limit(1).single();

  if (!data) return new Response(JSON.stringify({ ok: false, error: "Invalid or expired code" }), { status: 400 });

  await supabase.from("otp_verifications").update({ verified: true }).eq("id", data.id);
  return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" }});
});
```
Deploy: `supabase functions deploy verify-otp`

## 4. `supabase/functions/razorpay-webhook/index.ts`
Set this URL in Razorpay Dashboard → Settings → Webhooks:
`https://YOUR_PROJECT_REF.supabase.co/functions/v1/razorpay-webhook`
Event to send: `payment_link.paid`

```ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  const body = await req.text();
  const signature = req.headers.get("x-razorpay-signature")!;
  const secret = Deno.env.get("RAZORPAY_WEBHOOK_SECRET")!;

  // verify signature (HMAC SHA256)
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sigBuffer = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const expected = Array.from(new Uint8Array(sigBuffer)).map(b => b.toString(16).padStart(2,"0")).join("");
  if (expected !== signature) return new Response("Invalid signature", { status: 400 });

  const payload = JSON.parse(body);
  const paymentId = payload.payload.payment.entity.id;
  const notes = payload.payload.payment.entity.notes; // { user_id, coupon_code }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const expires = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  const { data: payment } = await supabase.from("payments").insert({
    user_id: notes.user_id, amount: 100, coupon_code: notes.coupon_code || null,
    razorpay_payment_id: paymentId, status: "paid", access_expires_at: expires
  }).select().single();

  // auto-generate bill record
  const gst = 100 * 0.18;
  await supabase.from("bills").insert({
    bill_number: `DAMT-${Date.now()}`,
    payment_id: payment.id, user_id: notes.user_id,
    amount: 100, gst_amount: gst, total_amount: 100 + gst
  });

  return new Response("ok");
});
```
Deploy: `supabase functions deploy razorpay-webhook`
```
supabase secrets set RAZORPAY_WEBHOOK_SECRET=whatever_you_set_in_razorpay_dashboard
```

## 5. Where to put your Razorpay Payment Link
In `index.html`, search for `RAZORPAY_PAYMENT_LINK` and replace with your real
link from Razorpay Dashboard → Payment Links. Add `?notes[user_id]=` handling
isn't supported on hosted links directly — instead use **Razorpay Orders API**
via a small Edge Function if you want the coupon-adjusted amount to be exact.
For a quick start, the app opens your fixed ₹100 payment link and asks the
user to paste the Razorpay Payment ID back in (shown on their success page) —
simple, but you should upgrade to the Orders API + webhook flow above before
real launch, so nobody can unlock listings without actually paying.

## 6. Make your first admin account
Sign up once in the app normally, then in Supabase SQL Editor:
```sql
update profiles set is_admin = true where id = (select id from auth.users where email = 'you@example.com');
```
That email + whatever password you chose is now the separate admin login.
