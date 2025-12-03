// api/dns.js – Google DoH Proxy + ECS CHUẨN VIỆT NAM
const UPSTREAM = "https://dns.google/dns-query";

export default async function handler(req, res) {
  const { method, headers, url } = req;

  // 1. Lấy IP thật của người dùng (Vercel luôn có 1 trong 2)
  const realIp = (
    headers["x-forwarded-for"]?.split(",")[0]?.trim() ||
    headers["x-real-ip"] ||
    "127.0.0.1"
  );

  // 2. Tạo subnet /24 (Google chỉ chấp nhận /24 trở lên cho IPv4)
  const subnet = realIp.split(".").slice(0, 3).join(".") + ".0/24";

  // 3. Headers Google tin tưởng 100% để tính ECS
  const forwardHeaders = {
    Accept: headers["accept"] || "application/dns-message",
    "Content-Type": headers["content-type"] || "",
    "User-Agent": headers["user-agent"] || "DoH-Proxy",
    "Accept-Encoding": headers["accept-encoding"] || "identity",

    // ←←← 3 header BẮT BUỘC để Google dùng ECS của bạn thay vì IP Vercel
    "X-Forwarded-For": realIp,
    "CF-Connecting-IP": realIp,
    "Edns-Client-Subnet": subnet,           // Header QUAN TRỌNG NHẤT!
  };

  const targetUrl = method === "POST" 
    ? UPSTREAM 
    : UPSTREAM + new URL(url, "http://localhost").search;

  try {
    const resp = await fetch(targetUrl, {
      method,
      headers: forwardHeaders,
      body: method === "POST" ? req : null,
      redirect: "follow",
    });

    // Copy toàn bộ header từ Google
    resp.headers.forEach((v, k) => res.setHeader(k, v));
    res.status(resp.status);

    const buffer = Buffer.from(await resp.arrayBuffer());
    res.setHeader("Content-Length", buffer.length);
    res.end(buffer);
  } catch (e) {
    console.error(e);
    res.status(502).end("Bad Gateway");
  }
}

export const config = {
  api: {
    bodyParser: false,   // bắt buộc cho POST binary
  },
};
