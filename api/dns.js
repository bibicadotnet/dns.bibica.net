const UPSTREAM = "https://dns.google/resolve";

export const config = { runtime: "edge" };

export default async function handler(request) {
  const url = new URL(request.url);
  const realIp = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
                 request.headers.get("cf-connecting-ip") ||
                 "1.1.1.1";

  const headers = new Headers(request.headers);
  headers.set("X-Forwarded-For", realIp);
  headers.set("CF-Connecting-IP", realIp);
  headers.set("True-Client-IP", realIp);
  headers.delete("host");

  const targetUrl = request.method === "POST" ? UPSTREAM : `${UPSTREAM}${url.search}`;

  const response = await fetch(targetUrl, {
    method: request.method,
    headers,
    body: request.body,
    redirect: "follow",
  });

  return new Response(response.body, {
    status: response.status,
    headers: response.headers,
  });
}
