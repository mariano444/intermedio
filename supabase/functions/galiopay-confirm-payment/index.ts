import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method === "GET") {
    return new Response(
      "<!doctype html><meta charset='utf-8'><title>Pago recibido</title><body style='font-family:system-ui;background:#050a02;color:#f5c842;display:grid;place-items:center;min-height:100vh;text-align:center'><main><h1>Pago recibido</h1><p>Volvé a El Intermedio para actualizar tu saldo.</p></main></body>",
      { headers: { "Content-Type": "text/html; charset=utf-8" } },
    );
  }
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const { referenceId, paymentLinkId, proofToken, amount, userId } = await req.json();
    if (!referenceId || !paymentLinkId || !proofToken || !userId) {
      return jsonResponse({ error: "Datos de pago incompletos" }, 400);
    }

    const linkResponse = await fetch(
      `https://pay.galio.app/api/payment-links/${paymentLinkId}?proof=${encodeURIComponent(proofToken)}`,
    );
    const link = await linkResponse.json().catch(() => ({}));
    if (!linkResponse.ok) return jsonResponse({ error: link.error || "No se pudo verificar el pago" }, 400);
    if (link.referenceId !== referenceId) return jsonResponse({ error: "Referencia de pago inválida" }, 400);
    if (!["approved", "paid"].includes(String(link.status).toLowerCase())) {
      return jsonResponse({ ok: false, status: link.status || "pending" });
    }

    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data, error } = await supabase.rpc("confirmar_deposito_galiopay", {
      p_referencia: referenceId,
      p_payment_id: link.paymentId || paymentLinkId,
      p_usuario_id: userId,
      p_monto: Number(amount),
    });
    if (error) throw error;

    return jsonResponse({ ok: true, result: data?.[0] || data });
  } catch (error) {
    return jsonResponse({ error: error.message || "Error confirmando pago" }, 500);
  }
});
