import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  const body = await req.text();
  const signature = req.headers.get("x-razorpay-signature")!;
  const secret = Deno.env.get("RAZORPAY_WEBHOOK_SECRET")!;

  // Verify this request genuinely came from Razorpay (HMAC SHA256)
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sigBuffer = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const expected = Array.from(new Uint8Array(sigBuffer)).map(b => b.toString(16).padStart(2,"0")).join("");
  if (expected !== signature) return new Response("Invalid signature", { status: 400 });

  const payload = JSON.parse(body);

  // Only act on successful payment events
  const eventType = payload.event;
  if (eventType !== "payment_link.paid" && eventType !== "payment.captured") {
    return new Response("ignored", { status: 200 });
  }

  const paymentEntity = payload.payload.payment.entity;
  const paymentId = paymentEntity.id;
  const notes = paymentEntity.notes || {};
  const userId = notes.user_id;
  const amountCharged = paymentEntity.amount / 100; // paise -> rupees

  if (!userId) {
    // No user_id note means we can't attribute this payment — log and stop.
    return new Response("no user_id in notes", { status: 200 });
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Avoid double-processing if Razorpay retries the webhook
  const { data: existing } = await supabase.from("payments")
    .select("id").eq("razorpay_payment_id", paymentId).maybeSingle();
  if (existing) return new Response("already processed", { status: 200 });

  const expires = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  const { data: payment, error } = await supabase.from("payments").insert({
    user_id: userId, amount: amountCharged,
    razorpay_payment_id: paymentId, status: "paid", access_expires_at: expires
  }).select().single();

  if (error) return new Response(JSON.stringify(error), { status: 500 });

  // GST-inclusive: base + GST add up to what was actually charged
  const gst = +(amountCharged * 0.18).toFixed(2);
  const baseAmount = +(amountCharged - gst).toFixed(2);
  await supabase.from("bills").insert({
    bill_number: `DAMT-${Date.now()}`,
    payment_id: payment.id, user_id: userId,
    amount: baseAmount, gst_amount: gst, total_amount: amountCharged
  });

  // Notify admin's Telegram
  const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
  const adminChatId = Deno.env.get("TELEGRAM_ADMIN_CHAT_ID");
  if (botToken && adminChatId) {
    const { data: profile } = await supabase.from("profiles").select("full_name").eq("id", userId).maybeSingle();
    fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: adminChatId,
        text: `💰 DAMT RENTAL payment received\nUser: ${profile?.full_name || userId}\nAmount: ₹${amountCharged}\nRazorpay Payment ID: ${paymentId}\nAccess granted: 24 hours`
      }),
    }).catch(() => {});
  }

  return new Response("ok", { status: 200 });
});
