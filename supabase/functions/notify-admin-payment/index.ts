import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

serve(async (req) => {
  try {
    const { user_email, amount, razorpay_payment_id, coupon_code } = await req.json();

    const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
    const adminChatId = Deno.env.get("TELEGRAM_ADMIN_CHAT_ID");

    const text =
      `💰 New DAMT RENTAL payment received\n` +
      `User: ${user_email}\n` +
      `Amount: ₹${amount}\n` +
      (coupon_code ? `Coupon: ${coupon_code}\n` : ``) +
      `Razorpay Payment ID: ${razorpay_payment_id}\n` +
      `Access granted: 24 hours`;

    await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: adminChatId, text }),
    });

    return new Response(JSON.stringify({ ok: true }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: String(e) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
