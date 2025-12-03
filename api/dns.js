// api/dns.js
const UPSTREAM = "https://8.8.8.8/dns-query";

export default async function handler(req, res) {
  const { method, headers, url } = req;

  // Lấy IP thật của user (Vercel headers)
  const realIp = headers["x-forwarded-for"]?.split(",")[0] ||
                 headers["x-real-ip"] ||
                 req.socket.remoteAddress;

  const newHeaders = new Headers();
  for (const [k, v] of Object.entries(headers)) {
    if (!k.startsWith("x-") && k !== "host" && k !== "connection") {
      newHeaders.set(k, v);
    }
  }

  newHeaders.set("X-Forwarded-For", realIp);
  newHeaders.set("CF-Connecting-IP", realIp);

  const upstreamUrl = UPSTREAM + new URL(url).search;

  const response = await fetch(method === "POST" ? UPSTREAM : upstreamUrl, {
    method,
    headers: newHeaders,
    body: method === "POST" ? req : undefined,
    redirect: "follow",
  });

  res.status(response.status);
  for (const [k, v] of response.headers) res.setHeader(k, v);
  return response.body ? res.send(await response.arrayBuffer()) : res.end();
}

export const config = {
  api: { bodyParser: false },
};
