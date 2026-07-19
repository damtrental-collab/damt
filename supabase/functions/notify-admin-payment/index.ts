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
  const amountCharged = payload.payload.payment.entity.amount / 100; // paise -> rupees

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const expires = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  const { data: payment } = await supabase.from("payments").insert({
    user_id: notes.user_id, amount: amountCharged, coupon_code: notes.coupon_code || null,
    razorpay_payment_id: paymentId, status: "paid", access_expires_at: expires
  }).select().single();

  // GST-inclusive: the amount charged already includes 18% GST,
  // so base + GST add up to the amount actually charged (not on top of it)
  const gst = +(amountCharged * 0.18).toFixed(2);
  const baseAmount = +(amountCharged - gst).toFixed(2);
  await supabase.from("bills").insert({
    bill_number: `DAMT-${Date.now()}`,
    payment_id: payment.id, user_id: notes.user_id,
    amount: baseAmount, gst_amount: gst, total_amount: amountCharged
  });

  return new Response("ok");
});
