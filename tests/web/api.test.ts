import { afterEach, describe, it, expect, vi } from "vitest";
import {
  Client,
  ApiError,
  emptyReceipt,
  emptyLine,
} from "../../src/web/src/api";
const user = {
  user_id: "admin",
  username: "admin",
  is_admin: true,
  must_change_password: true,
};
const session = (token: string) => ({
  access_token: token,
  expires_in: 900,
  user,
});
describe("browser authentication contract", () => {
  afterEach(() => vi.unstubAllGlobals());
  it("queries and creates receipts and lines when randomUUID is unavailable", async () => {
    const browserCrypto = globalThis.crypto;
    vi.stubGlobal("crypto", {
      getRandomValues: browserCrypto.getRandomValues.bind(browserCrypto),
    });
    const transport = vi.fn(
      async (_path: RequestInfo | URL, _init?: RequestInit) =>
        new Response(JSON.stringify({ data: [] })),
    );
    const c = new Client(transport);
    c.accept(session("jwt"));
    await c.op("receipts", "list");
    const receipt = emptyReceipt();
    receipt.lines = [emptyLine()];
    await c.op("receipts", "create", { receipt });
    const ids = [
      receipt.id,
      receipt.lines[0].id,
      ...transport.mock.calls.map(
        ([, init]) => JSON.parse(init?.body as string).request_key,
      ),
    ];
    expect(ids).toHaveLength(4);
    for (const id of ids)
      expect(id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
      );
    expect(new Set(ids).size).toBe(ids.length);
  });
  it("reports unsupported secure randomness rather than generating weak IDs", () => {
    vi.stubGlobal("crypto", {});
    expect(emptyReceipt).toThrow("浏览器不支持安全随机数，请更新浏览器后重试");
  });
  it("uses the browser fetch receiver for login, refresh, queries and photo uploads", async () => {
    const transport = vi.fn(async function (
      this: typeof globalThis,
      input: RequestInfo | URL,
      _init?: RequestInit,
    ) {
      if (this !== globalThis)
        throw new TypeError(
          "'fetch' called on an object that does not implement interface Window.",
        );
      const path = String(input);
      return new Response(
        JSON.stringify(
          path.startsWith("/api/auth/")
            ? session("browser-jwt")
            : { data: path.endsWith("/upload") ? { image_id: "photo" } : [] },
        ),
      );
    });
    vi.stubGlobal("fetch", transport);
    const c = new Client();
    await c.login("admin", "admin");
    await c.refresh();
    expect(await c.op("receipts", "list")).toEqual([]);
    expect(
      await c.upload(
        { id: "receipt", revision: 1 },
        new Blob(["photo"], { type: "image/jpeg" }),
        false,
        "upload-key",
      ),
    ).toEqual({ image_id: "photo" });
    expect(transport.mock.calls.map(([path]) => path)).toEqual([
      "/api/auth/login",
      "/api/auth/refresh",
      "/api/v1/receipts/list",
      "/api/v1/images/upload",
    ]);
    expect(
      transport.mock.calls.every(
        ([, init]) => init?.credentials === "same-origin",
      ),
    ).toBe(true);
    expect(transport.mock.calls[3][1]?.body).toBeInstanceOf(FormData);
  });
  it("keeps tokens in memory and preserves forced password change", async () => {
    const transport = vi
      .fn()
      .mockResolvedValue(
        new Response(JSON.stringify(session("jwt")), { status: 200 }),
      );
    const c = new Client(transport);
    const changed = vi.fn();
    c.onUser = changed;
    await c.login("admin", "admin");
    expect(c.user?.must_change_password).toBe(true);
    expect(c.token).toBe("jwt");
    expect(transport.mock.calls[0][1].credentials).toBe("same-origin");
    expect(changed).toHaveBeenCalledWith(user);
  });
  it("coalesces refresh requests and signs business requests with JWT", async () => {
    const transport = vi
      .fn()
      .mockImplementation(
        async (path: string) =>
          new Response(
            JSON.stringify(
              path === "/api/auth/refresh"
                ? session("fresh")
                : { data: [], catalog_version: 7 },
            ),
            { status: 200 },
          ),
      );
    const c = new Client(transport);
    await Promise.all([c.op("receipts", "list"), c.op("categories", "list")]);
    expect(
      transport.mock.calls.filter((c) => c[0] === "/api/auth/refresh"),
    ).toHaveLength(1);
    expect(transport.mock.calls[1][1].headers.Authorization).toBe(
      "Bearer fresh",
    );
    expect(c.version).toBe(7);
  });
  it("clears expired sessions, preserves failed-login errors and provides no client key fallback", async () => {
    const transport = vi.fn().mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            error: { code: "unauthenticated", message: "请登录" },
          }),
          { status: 401 },
        ),
    );
    const c = new Client(transport);
    await expect(c.refresh()).rejects.toBeInstanceOf(ApiError);
    expect(c.user).toBeNull();
    expect(c.token).toBe("");
    await expect(c.login("admin", "bad")).rejects.toThrow("请登录");
    expect(transport.mock.calls[0][1].headers.Authorization).toBeUndefined();
  });
});

describe("session recovery boundaries", () => {
  it("preserves a session on a temporary network error", async () => {
    const c = new Client(vi.fn().mockRejectedValue(new TypeError("offline")));
    c.accept(session("existing"));
    await expect(c.refresh()).rejects.toThrow("offline");
    expect(c.token).toBe("existing");
  });
  it("does not resurrect a session when its refresh completes after logout", async () => {
    let resolve!: (r: Response) => void;
    const c = new Client(
      vi
        .fn()
        .mockImplementation(() => new Promise<Response>((r) => (resolve = r))),
    );
    const refresh = c.refresh();
    c.clear();
    resolve(new Response(JSON.stringify(session("late"))));
    await expect(refresh).rejects.toThrow("账户已变更");
    expect(c.user).toBeNull();
    expect(c.token).toBe("");
  });
  it("never retries an old account's write under a new account", async () => {
    let resolve!: (r: Response) => void;
    const transport = vi
      .fn()
      .mockImplementation(() => new Promise<Response>((r) => (resolve = r)));
    const c = new Client(transport);
    c.accept(session("alice"));
    const request = c.op("receipts", "save", {
      receipt: { id: "alice-receipt" },
    });
    await Promise.resolve();
    c.clear();
    c.accept({ ...session("bob"), user: { ...user, user_id: "bob" } });
    resolve(
      new Response(JSON.stringify({ error: { code: "unauthenticated" } }), {
        status: 401,
      }),
    );
    await expect(request).rejects.toThrow("账户已变更");
    expect(transport).toHaveBeenCalledTimes(1);
  });
});

describe("offline reads and timeout recovery", () => {
  it("retains cached account and reads across reloads, tries the server, and never caches writes", async () => {
    const entries = new Map<string, string>();
    const storage: Storage = {
      get length() {
        return entries.size;
      },
      key: (i) => [...entries.keys()][i] ?? null,
      getItem: (key) => entries.get(key) ?? null,
      setItem: (key, value) => {
        entries.set(key, value);
      },
      removeItem: (key) => {
        entries.delete(key);
      },
      clear: () => entries.clear(),
    };
    const online = new Client(
      vi
        .fn()
        .mockResolvedValue(
          new Response(
            JSON.stringify({ data: ["receipt"], catalog_version: 3 }),
          ),
        ),
    );
    online.offlineStorage = storage;
    online.accept(session("jwt"));
    expect(await online.op("receipts", "list")).toEqual(["receipt"]);
    const transport = vi.fn().mockRejectedValue(new TypeError("offline"));
    const offline = new Client(transport);
    offline.offlineStorage = storage;
    offline.restoreCachedAccount();
    expect(offline.user?.username).toBe("admin");
    expect(await offline.op("receipts", "list")).toEqual(["receipt"]);
    await expect(offline.op("receipts", "save")).rejects.toThrow("offline");
    expect(transport).toHaveBeenCalledTimes(2);
    expect(offline.user?.username).toBe("admin");
    expect(transport.mock.calls[0][1].body).toBe(
      transport.mock.calls[1][1].body,
    );
    offline.clear();
    expect(storage.getItem("rm-offline-account")).toBeNull();
    expect([...entries.keys()].filter((k) => k.startsWith("rm-read:"))).toEqual(
      [],
    );
  });
  it("aborts a timed-out request without clearing the session and connects on the next attempt", async () => {
    vi.useFakeTimers();
    try {
      let timeout = true;
      const transport = vi.fn(
        async (_path: RequestInfo | URL, init?: RequestInit) => {
          if (!timeout)
            return new Response(
              JSON.stringify({ data: [], catalog_version: 1 }),
            );
          return new Promise<Response>((_, reject) =>
            init?.signal?.addEventListener("abort", () =>
              reject(new DOMException("aborted", "AbortError")),
            ),
          );
        },
      );
      const client = new Client(transport);
      client.accept(session("jwt"));
      const request = expect(client.op("receipts", "list")).rejects.toThrow(
        "Timeout",
      );
      await vi.advanceTimersByTimeAsync(30000);
      await request;
      expect(client.user?.username).toBe("admin");
      expect(client.token).toBe("jwt");
      timeout = false;
      expect(await client.op("receipts", "list")).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });
});
