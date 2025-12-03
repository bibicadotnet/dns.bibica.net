export default async function handler(req, res) {
    const clientIP = req.headers['x-forwarded-for']?.split(',')[0]?.trim();
    const url = new URL(req.url, `https://${req.headers.host}`);

    if (clientIP && !url.searchParams.has('edns_client_subnet')) {
        url.searchParams.set('edns_client_subnet', clientIP);
    }
    
    const target = 'https://8.8.8.8/dns-query' + url.search;
    
    const options = {
        method: req.method,
        headers: {
            'Accept': req.headers.accept || 'application/dns-message',
        }
    };
    
    if (req.method === 'POST') {
        options.headers['Content-Type'] = req.headers['content-type'] || 'application/dns-message';
        const chunks = [];
        for await (const chunk of req) {
            chunks.push(chunk);
        }
        options.body = Buffer.concat(chunks);
    }
    
    const upstream = await fetch(target, options);
    const data = await upstream.arrayBuffer();
    
    res.setHeader('Content-Type', upstream.headers.get('Content-Type') || 'application/dns-message');
    res.status(upstream.status).send(Buffer.from(data));
}
