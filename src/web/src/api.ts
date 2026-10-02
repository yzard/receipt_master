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
  private epoch = 0;
  private refreshing: Promise<void> | null = null;
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
    const response = await this.transport(path, {
      method,
      credentials: "same-origin",
      headers: {
        ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
        ...(authenticated ? { Authorization: `Bearer ${this.token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const data = await response.json();
    if (!response.ok)
      throw new ApiError(
        response.status,
        data.error?.code ?? "request_failed",
        data.error?.message ?? "请求失败",
      );
    return data;
  }
  accept(session: Row) {
    this.token = session.access_token;
    this.expires = Date.now() + session.expires_in * 1000;
    this.user = session.user;
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
      const session = await this.raw("/api/auth/refresh", {});
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
    this.token = "";
    this.user = null;
    this.expires = 0;
    this.version = 0;
    this.onUser(null);
  }
  async ready() {
    if (this.expires < Date.now() + 30000) await this.refresh();
  }
  async auth(path: string, body?: unknown, method = "POST") {
    await this.ready();
    try {
      return await this.raw(`/api/auth/${path}`, body, method, true);
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) this.clear();
      throw e;
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
    const response = await this.transport("/api/v1/images/upload", {
      method: "POST",
      credentials: "same-origin",
      headers: { Authorization: `Bearer ${this.token}` },
      body,
    });
    const result = await response.json();
    if (!response.ok)
      throw new ApiError(
        response.status,
        result.error?.code,
        result.error?.message ?? "照片上传失败",
      );
    return result.data;
  }
}
export const api = new Client();
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
    : new Intl.NumberFormat(undefined, {
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
    ? new Date(n).toLocaleString(undefined, {
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
