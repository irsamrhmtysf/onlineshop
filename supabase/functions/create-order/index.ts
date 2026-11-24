import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    const body = await request.json();
    if (!isRecord(body)) {
      return jsonResponse({ error: "Please provide a valid order request." }, 400);
    }
    const name = typeof body.name === "string" ? body.name.trim() : "";
    const phone = typeof body.phone === "string" ? body.phone.trim() : "";
    const address = typeof body.address === "string" ? body.address.trim() : "";
    const shippingZone = typeof body.shippingZone === "string" ? body.shippingZone : "";
    const items = Array.isArray(body.items) ? body.items : null;

    if (
      name.length < 2 || name.length > 120 ||
      phone.length < 8 || phone.length > 24 ||
      address.length < 8 || address.length > 1000 ||
      !/^\d{8,24}$/.test(phone) ||
      !["dekat", "sedang", "jauh"].includes(shippingZone) ||
      !items || items.length < 1 || items.length > 30
    ) {
      return jsonResponse({ error: "Please provide valid order details." }, 400);
    }

    const normalizedItems: Array<{ id: string; qty: number }> = [];
    for (const item of items) {
      if (
        !isRecord(item) ||
        typeof item.id !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(item.id) ||
        typeof item.qty !== "number" ||
        !Number.isSafeInteger(item.qty) ||
        item.qty < 1 ||
        item.qty > 9999
      ) {
        return jsonResponse({ error: "The cart contains an invalid product or quantity." }, 400);
      }
      normalizedItems.push({ id: item.id, qty: item.qty });
    }

    const url = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceRoleKey) {
      console.error("Supabase order function is missing server configuration.");
      return jsonResponse({ error: "Order service is not configured." }, 500);
    }

    const supabase = createClient(url, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data, error } = await supabase.rpc("place_order", {
      p_customer_name: name,
      p_customer_phone: phone,
      p_shipping_address: address,
      p_shipping_zone: shippingZone,
      p_items: normalizedItems,
    });

    if (error) {
      return jsonResponse({ error: error.message }, 400);
    }

    return jsonResponse({ order: data }, 201);
  } catch (error) {
    console.error("Unable to create order:", error);
    if (error instanceof SyntaxError) {
      return jsonResponse({ error: "The order request must contain valid JSON." }, 400);
    }
    return jsonResponse({ error: "Unable to create the order. Please try again." }, 500);
  }
});

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
