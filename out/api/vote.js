const KV_URL = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const KV_TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;

function send(res, status, payload) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("cache-control", "no-store");
  res.end(JSON.stringify(payload));
}

async function redis(path, init = {}) {
  const response = await fetch(`${KV_URL}${path}`, {
    ...init,
    headers: {
      authorization: `Bearer ${KV_TOKEN}`,
      ...(init.headers || {}),
    },
  });
  if (!response.ok) {
    throw new Error(`KV ${response.status}`);
  }
  return response.json();
}

function voteKey(day) {
  return `jianglin:votes:day:${Number(day || 1)}`;
}

async function readTotals(day) {
  const data = await redis(`/hgetall/${encodeURIComponent(voteKey(day))}`);
  const raw = Array.isArray(data.result) ? data.result : [];
  const totals = {};
  for (let i = 0; i < raw.length; i += 2) {
    totals[raw[i]] = Number(raw[i + 1] || 0);
  }
  return totals;
}

module.exports = async function handler(req, res) {
  if (!KV_URL || !KV_TOKEN) {
    return send(res, 200, {
      mode: "local",
      totals: {},
      message: "KV is not configured; client should use local vote fallback.",
    });
  }

  try {
    if (req.method === "GET") {
      const url = new URL(req.url, "https://jianglin.local");
      const day = url.searchParams.get("day") || "1";
      return send(res, 200, { mode: "cloud", day: Number(day), totals: await readTotals(day) });
    }

    if (req.method === "POST") {
      let body = "";
      for await (const chunk of req) body += chunk;
      const payload = JSON.parse(body || "{}");
      const day = Number(payload.day || 1);
      const optionId = String(payload.optionId || "");
      if (!/^[a-z0-9_-]{2,64}$/.test(optionId)) {
        return send(res, 400, { error: "invalid optionId" });
      }
      await redis(`/hincrby/${encodeURIComponent(voteKey(day))}/${encodeURIComponent(optionId)}/1`, {
        method: "POST",
      });
      return send(res, 200, { mode: "cloud", day, selected: optionId, totals: await readTotals(day) });
    }

    res.setHeader("allow", "GET, POST");
    return send(res, 405, { error: "method not allowed" });
  } catch (error) {
    return send(res, 500, { error: "vote api failed", detail: String(error.message || error) });
  }
};
