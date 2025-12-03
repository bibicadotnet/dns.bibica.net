// api/dns.js – Google DoH Proxy + ECS 100% đúng
const UPSTREAM = "https://dns.google/dns-query";

export default async function handler(req, res) {
  const { method, headers, url } = req;

  // ==== LẤY IP THẬT CỦA USER (Vercel luôn có 1 trong 2 header này) ====
  const realIp =
    headers["x-forwarded-for"]?.split(",")[0].trim() ||
    headers["x-real-ip"] ||
    "1.1.1.1";

  // ==== Tạo headers mới – chỉ giữ những gì Google cần ====
  const forwardHeaders = {
    "accept": headers["accept"] || "application/dns-message",
    "content-type": headers["content-type"] || "",
    "user-agent": headers["user-agent"] || "",
    "accept-encoding": headers["accept-encoding"] || "",
    // ←←← 2 header QUAN TRỌNG NHẤT Google dùng để tính ECS
    "x-forwarded-for": realIp,
    "cf-connecting-ip": realIp,
  };

  // Xóa rác
  delete forwardHeaders.host;
  delete forwardHeaders.connection;

  const targetUrl = method === "POST" ? UPSTREAM : UPSTREAM + new URL(url, "http://localhost").search;

  try {
    const upstreamResponse = await fetch(targetUrl, {
      method,
      headers: forwardHeaders,
      body: method === "POST" ? req : null, // Vercel Serverless cho forward stream khi bodyParser: false
      redirect: "follow",
    });

    // Copy hết headers từ Google về
    upstreamResponse.headers.forEach((value, key) => {
      res.setHeader(key, value);
    });

    res.status(upstreamResponse.status);

    // Trả binary hoặc JSON nguyên vẹn
    const buffer = Buffer.from(await upstreamResponse.arrayBuffer());
    res.setHeader("content-length", buffer.length);
    res.end(buffer);
  } catch (e) {
    console.error(e);
    res.status(502).end("Bad Gateway");
  }
}

// BẮT BUỘC – tắt body parser để POST binary không bị parse lỗi
export const config = {
  api: {
    bodyParser: false,
  },
};
