const UPSTREAM = "https://doh.google/";

export const config = { runtime: "edge" };

export default function handler(request) {
  const url = new URL(request.url);

  const realIp = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
                 || request.headers.get("cf-connecting-ip")
                 || "1.1.1.1";

  const headers = new Headers(request.headers);
  headers.set("X-Forwarded-For", realIp);
  headers.set("CF-Connecting-IP", realIp);
  headers.delete("host");  // bắt buộc xóa

  let targetUrl = UPSTREAM + "dns-query";
  if (request.method === "GET") {
    targetUrl += url.search;
  }

  return fetch(targetUrl, {
    method: request.method,
    headers,
    body: request.method === "POST" ? request.body : null,
    redirect: "follow",
  });
}
