import Fastify from "fastify";
import websocket from "@fastify/websocket";

const PORT = Number(process.env.PORT ?? 8443);
const HOST = process.env.HOST ?? "0.0.0.0";
const WHISPER_DISABLED = process.env.WHISPER_DISABLED === "1";

const app = Fastify({
  logger: {
    level: "info",
    // No content logging. We deliberately reduce log surface to:
    // timestamp + duration + status. Request/response bodies, headers,
    // and IP addresses are stripped here.
    serializers: {
      req: (req) => ({
        method: req.method,
        url: req.url,
        // Don't log headers, IPs, or bodies.
      }),
      res: (res) => ({ statusCode: res.statusCode }),
    },
  },
  // Strip IP addresses at the framework level. Reverse proxy (Caddy) is
  // responsible for stripping X-Forwarded-For before we ever see it.
  trustProxy: false,
});

await app.register(websocket);

// Health check
app.get("/healthz", async () => ({ status: "ok", whisper: !WHISPER_DISABLED }));

// /transcribe — WebSocket; receives 16 kHz mono Int16 PCM, returns JSON segments.
app.get("/transcribe", { websocket: true }, (socket /* SocketStream */, req) => {
  if (WHISPER_DISABLED) {
    socket.send(JSON.stringify({ error: "not_implemented", reason: "whisper_disabled" }));
    socket.close();
    return;
  }
  // TODO Phase 2C: spawn faster-whisper subprocess, pipe PCM in, parse JSON out.
  // Until then, reply with the stub error.
  socket.send(JSON.stringify({ error: "not_implemented", reason: "stub" }));
  socket.close();
});

// /feedback/correction — receive a single opt-in correction.
app.post("/feedback/correction", async (req, reply) => {
  // Validate shape (light validation; full schema is in docs/feedback_channel_spec.md)
  const body = req.body;
  if (!body || typeof body !== "object" ||
      typeof body.session_token !== "string" ||
      typeof body.app_version !== "string" ||
      typeof body.audio_base64 !== "string" ||
      typeof body.match !== "object" ||
      typeof body.correction !== "object") {
    reply.code(400);
    return { error: "invalid_body" };
  }

  // TODO Phase 2A polish: write to FEEDBACK_QUEUE_DIR with a UUID filename,
  // encrypted at the filesystem layer. For now, accept the shape and
  // discard the body. We accept the request so the client UX is correct
  // even before deployment; nothing is persisted.
  reply.code(202);
  return { id: cryptoRandomId(), status: "accepted_but_not_persisted_yet" };
});

// /feedback/submissions — list / delete for a given session token.
app.get("/feedback/submissions", async (req, reply) => {
  // No persistence yet → empty list.
  return { submissions: [] };
});

app.delete("/feedback/submissions", async (req, reply) => {
  // No persistence yet → success no-op.
  return { deleted: 0 };
});

function cryptoRandomId() {
  return [...crypto.getRandomValues(new Uint8Array(12))]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

try {
  await app.listen({ port: PORT, host: HOST });
  app.log.info({ port: PORT, host: HOST, whisperDisabled: WHISPER_DISABLED },
                "gurbanilens server listening");
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
