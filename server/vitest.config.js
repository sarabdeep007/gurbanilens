import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Each *.test.js file gets its own process. We mutate env vars
    // (FEEDBACK_DISABLED, WHISPER_PYTHON, etc.) per file, and want
    // import side-effects to re-run cleanly.
    pool: "forks",
    isolate: true,
    fileParallelism: false,
    testTimeout: 15_000,
    include: ["test/**/*.test.js"],
  },
});
