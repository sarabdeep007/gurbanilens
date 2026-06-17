// PM2 ecosystem config for the gurbanilens server.
//
// Deployed alongside the other taaj-prod PM2 services. Port 4040 is
// pre-cleared against the existing process list (see CURRENT_STATE.md).
//
// Usage on taaj-prod:
//   pm2 start ecosystem.config.js --env production
//   pm2 save && pm2 startup
//
// Logs land in PM2's default log dir (~/.pm2/logs/). The privacy
// contract is *also* enforced at the application logger (no headers,
// no IPs, no bodies); PM2 just captures stdout/stderr as-is.

module.exports = {
  apps: [
    {
      name: "gurbanilens-server",
      script: "./src/index.js",
      interpreter: "node",
      cwd: __dirname,

      // Single fork — Whisper is CPU-bound so going cluster mode just
      // contends for the same cores. Scale by adding boxes later.
      instances: 1,
      exec_mode: "fork",

      // Restart on crash, but back off on rapid-fail loops.
      autorestart: true,
      max_restarts: 10,
      min_uptime: "30s",
      restart_delay: 5000,
      max_memory_restart: "2G",

      // Graceful shutdown — our SIGTERM handler closes Fastify + SQLite.
      kill_timeout: 10000,
      wait_ready: false,

      // Don't capture transcripts in PM2 logs. The app already filters
      // its own logger; PM2 only sees the JSON lines that survived
      // privacyLoggerConfig() in src/middleware/privacy.js.
      merge_logs: true,
      time: true,

      env: {
        NODE_ENV: "development",
        PORT: 4040,
      },
      env_production: {
        NODE_ENV: "production",
        PORT: 4040,
        HOST: "127.0.0.1",
        LOG_LEVEL: "info",
        // Required prod env (read from systemd-style EnvironmentFile
        // or /etc/gurbanilens/server.env on the host, not committed):
        //   FEEDBACK_HMAC_SECRET (openssl rand -hex 32)
        //   WHISPER_MODEL_PATH   (only if pre-downloading the model)
        //   WHISPER_MODEL=large-v3
      },
    },
  ],
};
