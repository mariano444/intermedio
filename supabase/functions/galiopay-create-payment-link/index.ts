import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";

const galioApiBase = "https://pay.galio.app/api";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const { userId, username, amount, successUrl, failureUrl } = await req.json();
    const numericAmount = Number(amount);
    if (!userId || !username) return jsonResponse({ error: "Usuario inválido" }, 400);
    if (!Number.isFinite(numericAmount) || numericAmount < 5000) {
      return jsonResponse({ error: "Monto mínimo de recarga: $5000" }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const galioClientId = Deno.env.get("GALIOPAY_CLIENT_ID")!;
    const galioApiKey = Deno.env.get("GALIOPAY_API_KEY")!;
    const sandbox = Deno.env.get("GALIOPAY_SANDBOX") === "true";
    const publicSiteUrl = Deno.env.get("PUBLIC_SITE_URL") || successUrl || "";
    const webhookUrl = `${supabaseUrl}/functions/v1/galiopay-webhook`;

    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const referenceId = `deposito_${userId}_${Date.now()}`;

    const { error: pendingError } = await supabase.rpc("registrar_deposito_pendiente", {
      p_usuario_id: userId,
      p_monto: numericAmount,
      p_referencia: referenceId,
    });
    if (pendingError) throw pendingError;

    const response = await fetch(`${galioApiBase}/payment-links`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${galioApiKey}`,
        "x-client-id": galioClientId,
      },
      body: JSON.stringify({
        items: [
          {
            title: `Recarga El Intermedio - ${username}`,
            quantity: 1,
            unitPrice: numericAmount,
            currencyId: "ARS",
          },
        ],
        referenceId,
        notificationUrl: webhookUrl,
        sandbox,
        backUrl: {
          success: successUrl || `${publicSiteUrl}?gp_state=success`,
          failure: failureUrl || `${publicSiteUrl}?gp_state=failure`,
        },
      }),
    });

    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      return jsonResponse({ error: data.error || "GalioPay rechazó el link" }, response.status);
    }

    const paymentLinkId = data.url?.match(/\/payment\/([^?]+)/)?.[1] || null;
    return jsonResponse({
      url: data.url,
      proofToken: data.proofToken,
      referenceId: data.referenceId || referenceId,
      paymentLinkId,
      sandbox: data.sandbox,
    }, 201);
  } catch (error) {
    return jsonResponse({ error: error.message || "Error creando link de pago" }, 500);
  }
});
