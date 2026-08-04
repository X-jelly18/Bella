import http from "http";
import https from "https";
import httpProxy from "http-proxy";

const PORT = process.env.PORT || 8080;
const TARGET = "https://south.ayanakojivps.shop:2053";

// 1. Create a Keep-Alive agent to prevent TLS handshake overhead on every request
const httpsAgent = new https.Agent({
  keepAlive: true,
  maxSockets: 100,
  maxFreeSockets: 10,
  timeout: 60000, 
});

// 2. Initialize proxy with the agent
const proxy = httpProxy.createProxyServer({
  target: TARGET,
  changeOrigin: true,
  ws: true,
  xfwd: true,
  agent: httpsAgent,
});

// 3. Drop Express and use the native HTTP module for maximum speed
const server = http.createServer((req, res) => {
  proxy.web(req, res, { target: TARGET }, (err) => {
    console.error("Proxy error:", err.message);
    if (!res.headersSent) {
      res.writeHead(502).end("Bad Gateway");
    }
  });
});

// 4. Optimize WebSocket upgrades
server.on("upgrade", (req, socket, head) => {
  // CRITICAL: Disable Nagle's algorithm. 
  // This forces TCP packets to send immediately instead of buffering, drastically reducing SSH keystroke lag.
  socket.setNoDelay(true);
  
  // Optional: keep-alive the socket at the TCP layer
  socket.setKeepAlive(true, 15000);

  proxy.ws(req, socket, head, { target: TARGET });
});

proxy.on("error", (err) => {
  console.error("Proxy internal error:", err.message);
});

server.listen(Number(PORT), "0.0.0.0", () => {
  console.log(`High-speed Cloud Run proxy running on :${PORT} → ${TARGET}`);
});
