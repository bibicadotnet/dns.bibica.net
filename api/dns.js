// api/dns.js – DoH Proxy cho Google Public DNS (binary + JSON)
const DOH_BINARY = 'https://dns.google/dns-query';  // Binary DoH (RFC 8484)
const DOH_JSON = 'https://dns.google/resolve';      // JSON API
const TYPE_DNS = 'application/dns-message';
const TYPE_JSON = 'application/dns-json';

export default async function handler(req, res) {
  const { method, headers, url: rawUrl } = req;
  const requestUrl = new URL(rawUrl, `http://${headers.host}`);
  const searchParams = requestUrl.searchParams;

  try {
    // Lấy IP thật của user cho ECS
    const realIp = headers['x-forwarded-for']?.split(',')[0]?.trim() ||
                   headers['cf-connecting-ip'] ||
                   headers['x-real-ip'] ||
                   '14.191.231.0';

    const newHeaders = {};
    Object.entries(headers).forEach(([key, value]) => {
      const lowerKey = key.toLowerCase();
      if (!lowerKey.startsWith('x-') && lowerKey !== 'host' && lowerKey !== 'connection') {
        newHeaders[key] = value;
      }
    });
    newHeaders['X-Forwarded-For'] = realIp;
    newHeaders['CF-Connecting-IP'] = realIp;
    newHeaders['True-Client-IP'] = realIp;  // Google đọc thêm

    let targetUrl, body, upstreamHeaders;

    if (method === 'GET') {
      if (searchParams.has('dns')) {
        targetUrl = `${DOH_BINARY}?dns=${searchParams.get('dns')}`;
        upstreamHeaders = { ...newHeaders, Accept: TYPE_DNS };
      }
      else if (headers.accept?.includes(TYPE_JSON)) {
        let jsonPath = requestUrl.search;
        if (!searchParams.has('name')) {
          return res.status(400).json({ error: 'name parameter required for JSON mode' });
        }
        targetUrl = `${DOH_JSON}${jsonPath}`;
        upstreamHeaders = { ...newHeaders, Accept: TYPE_JSON };
      } else {
        return res.status(404).send('');
      }
      body = undefined;
    } else if (method === 'POST') {
      // Mode 3: POST binary
      if (headers['content-type'] !== TYPE_DNS) {
        return res.status(404).send('');
      }
      targetUrl = DOH_BINARY;
      body = await getRawBody(req);
      upstreamHeaders = { ...newHeaders, 'Content-Type': TYPE_DNS, Accept: TYPE_DNS };
    } else {
      return res.status(405).send('Method Not Allowed');
    }

    const response = await fetch(targetUrl, {
      method,
      headers: upstreamHeaders,
      body,
      signal: AbortSignal.timeout(5000),
    });

    res.status(response.status);
    response.headers.forEach((value, key) => {
      res.setHeader(key, value);
    });

    // Stream body (binary hoặc JSON)
    const data = await response.arrayBuffer();
    res.setHeader('Content-Length', data.byteLength);
    res.end(Buffer.from(data));

  } catch (error) {
    console.error('DoH Proxy Error:', error);
    res.status(500).json({ error: 'Internal Server Error' });
  }
}

// Raw body cho POST binary (fix crash)
async function getRawBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

export const config = {
  api: {
    bodyParser: false,  // Bắt buộc: Tắt parser cho binary
  },
};
