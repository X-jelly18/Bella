import express from "express";
import httpProxy from "http-proxy";

const app = express();
const PORT = process.env.PORT || 8080;

// ===== your original target =====
const TARGET = "https://south.ayanakojivps.shop:2053";

// create proxy
const proxy = httpProxy.createProxyServer({
  target: TARGET,
  changeOrigin: true,
  ws: true,
  xfwd: true
});

// -----------------------------
// HTTP PROXY (same as Nginx → Node in VPS script)
// -----------------------------
app.use((req, res) => {
  proxy.web(
    req,
    res,
    { target: TARGET },
    (err) => {
      console.error("Proxy error:", err);
      if (!res.headersSent) {
        res.status(502).send("Bad Gateway");
      }
    }
  );
});

// -----------------------------
// WebSocket support (like nginx upgrade block)
// -----------------------------
const server = app.listen(Number(PORT), "0.0.0.0", () => {
  console.log(`Cloud Run proxy running on :${PORT} → ${TARGET}`);
});

server.on("upgrade", (req, socket, head) => {
  proxy.ws(req, socket, head, { target: TARGET });
});

// -----------------------------
// Error handling (like your proxy.on("error"))
// -----------------------------
proxy.on("error", (err) => {
  console.error("Proxy internal error:", err);
});
