import { formatLocale } from "./i18n";
import { newId } from "./id";

export type Row = Record<string, any>;
export type User = {
  user_id: string;
  username: string;
  is_admin: boolean;
  must_change_password: boolean;
};
export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
  ) {
    super(message);
  }
}
export class Client {
  user: User | null = null;
  token = "";
  expires = 0;
  version = 0;
  onUser: (user: User | null) => void = () => {};
  offlineStorage: Storage | null = null;
  offlineMessage = "";
  onConnectivity: (message: string) => void = () => {};
  private setConnectivity(message: string) {
    this.offlineMessage = message;
    this.onConnectivity(message);
  }
  restoreCachedAccount() {
    try {
      const user = JSON.parse(
        this.offlineStorage?.getItem("rm-offline-account") ?? "null",
      );
      if (
        typeof user?.user_id === "string" &&
        typeof user?.username === "string"
      ) {
        this.user = user;
        this.onUser(user);
      }
    } catch {
      /* Ignore damaged device metadata. */
    }
  }
  private epoch = 0;
  private refreshing: Promise<void> | null = null;
  private pendingRefreshKey: string | null = null;
  constructor(
    private transport: typeof fetch = (input, init) =>
      globalThis.fetch(input, init),
  ) {}
  private async raw(
    path: string,
    body?: unknown,
    method = "POST",
    authenticated = false,
  ): Promise<any> {
    return this.request(
      path,
      {
        method,
        credentials: "same-origin",
        headers: {
          ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
          ...(authenticated ? { Authorization: `Bearer ${this.token}` } : {}),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      },
      30000,
      "请求失败",
    );
  }
  private async request(
    path: string,
    init: RequestInit,
    timeoutMs: number,
    failureMessage: string,
  ): Promise<Row> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await this.transport(path, {
        ...init,
        signal: controller.signal,
      });
      const data = await response.json();
      if (!response.ok)
        throw new ApiError(
          response.status,
          data.error?.code ?? "request_failed",
          data.error?.message ?? failureMessage,
        );
      return data;
    } catch (error) {
      if (controller.signal.aborted)
        throw new ApiError(0, "timeout", "Timeout");
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }

  accept(session: Row) {
    this.pendingRefreshKey = null;
    try {
      this.offlineStorage?.removeItem("rm-refresh-request");
    } catch {
      /* Storage is optional. */
    }
    this.token = session.access_token;
    this.expires = Date.now() + session.expires_in * 1000;
    this.user = session.user;
    try {
      this.offlineStorage?.setItem(
        "rm-offline-account",
        JSON.stringify(this.user),
      );
    } catch {
      /* Storage can be unavailable. */
    }
    this.onUser(this.user);
  }
  async login(username: string, password: string) {
    const epoch = ++this.epoch;
    const session = await this.raw("/api/auth/login", { username, password });
    if (epoch === this.epoch) this.accept(session);
  }
  refresh(): Promise<void> {
    if (this.refreshing) return this.refreshing;
    const epoch = this.epoch;
    const run = async () => {
      const requestKey =
        this.pendingRefreshKey ??
        this.offlineStorage?.getItem("rm-refresh-request") ??
        newId();
      this.pendingRefreshKey = requestKey;
      try {
        this.offlineStorage?.setItem("rm-refresh-request", requestKey);
      } catch {
        /* Retain the key in memory. */
      }
      const session = await this.raw("/api/auth/refresh", {
        request_key: requestKey,
      });
      if (epoch !== this.epoch) throw new Error("账户已变更");
      this.accept(session);
    };
    // Cookies are shared by tabs; serialize their rotation across the same origin.
    const request =
      typeof navigator !== "undefined" && navigator.locks
        ? navigator.locks.request("receipt-master-refresh", run)
        : run();
    return (this.refreshing = request
      .catch((e) => {
        if (epoch === this.epoch && e instanceof ApiError && e.status === 401)
          this.clear();
        throw e;
      })
      .finally(() => {
        this.refreshing = null;
      }));
  }
  clear() {
    this.epoch++;
    this.pendingRefreshKey = null;
    this.token = "";
    this.user = null;
    this.expires = 0;
    this.version = 0;
    try {
      this.offlineStorage?.removeItem("rm-offline-account");
      this.offlineStorage?.removeItem("rm-refresh-request");
      this.dropReadCache();
    } catch {
      /* Logout must work without device storage. */
    }
    this.onUser(null);
  }
  private dropReadCache() {
    const storage = this.offlineStorage;
    if (!storage) return;
    const keys = Array.from({ length: storage.length }, (_, i) =>
      storage.key(i),
    );
    for (const key of keys)
      if (key?.startsWith("rm-read:")) storage.removeItem(key);
  }
  async ready() {
    if (this.expires < Date.now() + 30000) await this.refresh();
  }
  async auth(path: string, body?: unknown, method = "POST") {
    await this.ready();
    try {
      return await this.raw(`/api/auth/${path}`, body, method, true);
    } catch (e) {
      if (!(e instanceof ApiError) || e.status !== 401) throw e;
      await this.refresh();
      return this.raw(`/api/auth/${path}`, body, method, true);
    }
  }
  async change(current_password: string, new_password: string) {
    this.accept(
      await this.auth("change-password", { current_password, new_password }),
    );
  }
  async logout() {
    const epoch = this.epoch;
    try {
      await this.auth("logout", {});
    } finally {
      if (epoch === this.epoch) this.clear();
    }
  }
  async op(
    component: string,
    operation: string,
    input: Row = {},
    key: string = newId(),
  ): Promise<any> {
    const account = this.user?.user_id;
    const cacheKey = `rm-read:${JSON.stringify([account, component, operation, input])}`;
    const readable = cachedReads.has(`${component}/${operation}`);
    try {
      const data = await this.opOnline(component, operation, input, key);
      this.setConnectivity("");
      try {
        if (readable && account)
          this.offlineStorage?.setItem(
            cacheKey,
            JSON.stringify({ data, version: this.version }),
          );
        else if (!readable) this.dropReadCache();
      } catch {
        /* A completed request does not depend on device storage. */
      }
      return data;
    } catch (error) {
      if (
        !(error instanceof TypeError) &&
        !(error instanceof ApiError && error.code === "timeout")
      )
        throw error;
      this.setConnectivity(
        error instanceof ApiError ? "Timeout" : "网络不可用，显示缓存",
      );
      if (readable && account === this.user?.user_id) {
        try {
          const cached = JSON.parse(
            this.offlineStorage?.getItem(cacheKey) ?? "null",
          );
          if (cached && typeof cached.version === "number") {
            this.version = cached.version;
            return cached.data;
          }
        } catch {
          /* Ignore damaged cache entries. */
        }
      }
      throw error;
    }
  }
  private async opOnline(
    component: string,
    operation: string,
    input: Row,
    key: string,
  ): Promise<any> {
    const account = this.user?.user_id;
    const epoch = this.epoch;
    await this.ready();
    const check = () => {
      if (epoch !== this.epoch || (account && account !== this.user?.user_id))
        throw new Error("账户已变更");
    };
    check();
    const path = `/api/v1/${component}/${operation}`;
    let result;
    try {
      result = await this.raw(path, { input, request_key: key }, "POST", true);
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) {
        check();
        await this.refresh();
        check();
        result = await this.raw(
          path,
          { input, request_key: key },
          "POST",
          true,
        );
      } else throw e;
    }
    if (typeof result.catalog_version === "number")
      this.version = result.catalog_version;
    return result.data;
  }
  async upload(
    receipt: Row,
    photo: Blob,
    camera: boolean,
    key: string,
    capturedAt: number | null = camera ? Date.now() : null,
  ): Promise<Row> {
    const account = this.user?.user_id;
    await this.ready();
    if (account !== this.user?.user_id) throw new Error("账户已变更");
    const body = new FormData();
    body.set(
      "metadata",
      JSON.stringify({
        request_key: key,
        input: {
          receipt_id: receipt.id,
          expected_version: receipt.revision,
          captured_at_utc_ms: capturedAt,
        },
      }),
    );
    body.set("photo", photo, "receipt.jpg");
    const send = () =>
      this.request(
        "/api/v1/images/upload",
        {
          method: "POST",
          credentials: "same-origin",
          headers: { Authorization: `Bearer ${this.token}` },
          body,
        },
        180000,
        "照片上传失败",
      );
    let result;
    try {
      result = await send();
    } catch (error) {
      if (!(error instanceof ApiError) || error.status !== 401) throw error;
      await this.refresh();
      if (account !== this.user?.user_id) throw new Error("账户已变更");
      result = await send();
    }
    return result.data;
  }
}
const cachedReads = new Set([
  "config/get",
  "receipts/list",
  "receipts/get",
  "images/list",
  "receipt_types/list",
  "merchants/list",
  "categories/list",
  "printed_names/list",
  "product_names/list",
  "products/suggest",
  "categories/suggest",
  "product_names/suggest",
  "reports/summary",
  "reports/trend",
  "recognition/get",
]);
export const api = new Client();
try {
  api.offlineStorage = globalThis.localStorage;
} catch {
  /* Storage is optional. */
}
export const zone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
export const currencies = [
  "USD",
  "CNY",
  "EUR",
  "GBP",
  "JPY",
  "CAD",
  "AUD",
  "KRW",
  "CHF",
  "HKD",
  "TWD",
  "SGD",
  "INR",
  "KWD",
  "BHD",
];
export const money = (n: number | null, c = "USD") =>
  n == null
    ? "—"
    : new Intl.NumberFormat(formatLocale(), {
        style: "currency",
        currency: c,
      }).format(
        n /
          10 **
            (c === "JPY" || c === "KRW"
              ? 0
              : c === "KWD" || c === "BHD"
                ? 3
                : 2),
      );
export const date = (n: number | null) =>
  n
    ? new Date(n).toLocaleString(formatLocale(), {
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "—";
export const emptyReceipt = (): Row => ({
  id: newId(),
  store: "",
  recognizedStore: "",
  receiptTypeId: null,
  branch: "",
  address: "",
  country: "US",
  currency: "USD",
  timeSource: "estimated_clock",
  rawTime: "",
  totalSource: "user_entered",
  occurredAt: Date.now(),
  createdAt: Date.now(),
  revision: 0,
  totalMinor: null,
  posted: false,
  lines: [],
});
export const emptyLine = (): Row => ({
  id: newId(),
  kind: "product",
  rawName: "",
  taxCode: null,
  sku: null,
  productNameEdit: null,
  categoryId: "00000000-0000-4000-8000-000000000001",
  receiptTypeId: null,
  productId: null,
  discountTarget: null,
  quantityUnit: null,
  weightMg: null,
  quantityMicros: null,
  unitPriceScaled: null,
  amountMinor: null,
  printedAmountMinor: null,
  warnings: [],
  evidence: [],
  display: {},
  isWeighed: false,
});
export async function receiptList(input: Row = {}) {
  let cursor = null;
  const rows: Row[] = [];
  do {
    const page = await api.op("receipts", "list", {
      sort_by: "created_at",
      direction: "desc",
      ...input,
      cursor,
    });
    rows.push(...page.items);
    cursor = page.next_cursor;
  } while (cursor);
  return rows;
}
export function download(name: string, bytes: BlobPart, type: string) {
  const url = URL.createObjectURL(new Blob([bytes], { type }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}
export const decode64 = (s: string) =>
  Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
export async function encode64(blob: Blob) {
  return new Promise<string>((resolve, reject) => {
    const r = new FileReader();
    r.onerror = reject;
    r.onload = () => resolve(String(r.result).split(",")[1]);
    r.readAsDataURL(blob);
  });
}
