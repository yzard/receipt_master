import { defineConfig } from "vitest/config";
export default defineConfig({
  resolve: {
    alias: [
      "react",
      "react-dom",
      "@testing-library/react",
      "@testing-library/user-event",
      "fake-indexeddb",
    ].map((name) => ({
      find: new RegExp("^" + name + "(?=/|$)"),
      replacement: new URL("./node_modules/" + name, import.meta.url).pathname,
    })),
  },
  server: { fs: { allow: ["../.."] } },
  build: { outDir: "../../build/web", emptyOutDir: true },
  test: { include: ["../../tests/web/**/*.test.{ts,tsx}"] },
});
