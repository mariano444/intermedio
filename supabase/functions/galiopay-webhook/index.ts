import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const payload = await req.json();
    const referenceId = payload.referenceId;
    const status = String(payload.status || "").toLowerCase();
    if (!referenceId) return jsonResponse({ error: "referenceId requerido" }, 400);

    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    if (status === "approved") {
      const { data, error } = await supabase.rpc("confirmar_deposito_galiopay", {
        p_referencia: referenceId,
        p_payment_id: payload.id,
        p_usuario_id: null,
        p_monto: Number(payload.amount || 0),
      });
      if (error) throw error;
      return jsonResponse({ ok: true, result: data?.[0] || data });
    }

    if (status === "refunded") {
      await supabase
        .from("movimientos")
        .update({ estado: "rechazado", descripcion: `Pago reembolsado por GalioPay: ${payload.id || ""}` })
        .eq("referencia_pago", referenceId);
      return jsonResponse({ ok: true });
    }

    return jsonResponse({ ok: true, ignored: status || "unknown" });
  } catch (error) {
    return jsonResponse({ error: error.message || "Error procesando webhook" }, 500);
  }
});
