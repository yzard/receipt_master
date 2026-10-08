// @vitest-environment jsdom
import React from "react";
import { describe, it, expect, vi, afterEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  waitFor,
  act,
} from "@testing-library/react";
import {
  SignIn,
  Receipts,
  TrendChart,
  LineEditor,
  AndroidDownloadLink,
  App,
} from "../../src/web/src/main";
import { api, emptyLine } from "../../src/web/src/api";
vi.mock("../../src/web/src/uploads", () => ({
  pending: async () => [],
  retry: vi.fn(async () => {}),
  enqueue: vi.fn(),
}));
afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
});
describe("interactive web workflows", () => {
  it("expires queue notices, restarts their duration, and clears them on navigation", async () => {
    const previous = api.user;
    vi.spyOn(api, "refresh").mockImplementation(async () => {
      api.user = {
        user_id: "notice-user",
        username: "notice-user",
        is_admin: false,
        must_change_password: false,
      };
      api.onUser(api.user);
    });
    vi.spyOn(api, "op").mockImplementation(async (component) =>
      component === "receipts" ? { items: [], next_cursor: null } : [],
    );
    try {
      const app = render(<App />);
      await screen.findByRole("heading", { name: "收据" });
      vi.useFakeTimers();
      const text = "已加入识别队列，可继续处理其他收据。";
      const notify = () =>
        act(() => {
          window.dispatchEvent(new CustomEvent("notice", { detail: text }));
        });
      notify();
      expect(screen.getByRole("status").textContent).toContain(text);
      act(() => vi.advanceTimersByTime(4000));
      notify();
      act(() => vi.advanceTimersByTime(1000));
      expect(screen.getByRole("status").textContent).toContain(text);
      act(() => vi.advanceTimersByTime(4000));
      expect(screen.queryByText(text)).toBeNull();
      notify();
      fireEvent.click(screen.getByRole("button", { name: "关闭提示" }));
      expect(screen.queryByText(text)).toBeNull();
      notify();
      fireEvent.click(screen.getByRole("button", { name: "打开导航菜单" }));
      fireEvent.click(screen.getByRole("button", { name: "商品" }));
      expect(screen.queryByText(text)).toBeNull();
      notify();
      app.unmount();
      act(() => vi.advanceTimersByTime(5000));
    } finally {
      cleanup();
      api.user = previous;
    }
  });
  it("opens the product navigation and dismisses the drawer without losing the page", async () => {
    const previous = api.user;
    vi.spyOn(api, "refresh").mockImplementation(async () => {
      api.user = {
        user_id: "layout-user",
        username: "layout-user",
        is_admin: false,
        must_change_password: false,
      };
      api.onUser(api.user);
    });
    vi.spyOn(api, "op").mockImplementation(async (component) =>
      component === "receipts" ? { items: [], next_cursor: null } : [],
    );
    try {
      render(<App />);
      fireEvent.click(
        await screen.findByRole("button", { name: "打开导航菜单" }),
      );
      expect(screen.getByRole("navigation", { name: "主导航" })).toBeTruthy();
      expect(screen.getByRole("button", { name: "商品" })).toBeTruthy();
      expect(screen.queryByRole("button", { name: "商品管理" })).toBeNull();
      fireEvent.click(screen.getByRole("button", { name: "关闭导航菜单" }));
      expect(screen.queryByRole("navigation", { name: "主导航" })).toBeNull();
      expect(screen.getByRole("heading", { name: "收据" })).toBeTruthy();
      fireEvent.click(screen.getByRole("button", { name: "打开导航菜单" }));
      fireEvent.click(screen.getByRole("button", { name: "商品" }));
      expect(
        await screen.findByRole("heading", { name: "商品管理" }),
      ).toBeTruthy();
      expect(screen.queryByRole("navigation", { name: "主导航" })).toBeNull();
    } finally {
      cleanup();
      api.user = previous;
    }
  });
  it("refreshes the login cookie before a same-origin APK download and stops on authentication failure", async () => {
    let ready!: () => void;
    const session = vi.spyOn(api, "ready").mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          ready = resolve;
        }),
    );
    const downloaded: string[] = [];
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (
      this: HTMLAnchorElement,
    ) {
      downloaded.push(this.getAttribute("href")!);
    });
    render(<AndroidDownloadLink className="android-download" />);
    const link = screen.getByRole("link", { name: "下载 Android APK" });
    expect(link.getAttribute("href")).toBe("/receipt_master.apk");
    fireEvent.click(link);
    expect(downloaded).toEqual([]);
    ready();
    await waitFor(() => expect(downloaded).toEqual(["/receipt_master.apk"]));
    session.mockRejectedValue(new Error("请先登录"));
    fireEvent.click(link);
    await waitFor(() => expect(session).toHaveBeenCalledTimes(2));
    expect(downloaded).toHaveLength(1);
  });
  it("submits password-manager login values even without React change events", async () => {
    const login = vi.spyOn(api, "login").mockResolvedValue();
    render(<SignIn />);
    const username = screen.getByLabelText("用户名") as HTMLInputElement;
    const password = screen.getByLabelText("密码") as HTMLInputElement;
    expect(username.name).toBe("username");
    expect(username.autocomplete).toBe("username");
    expect(password.name).toBe("password");
    expect(password.autocomplete).toBe("current-password");
    username.value = "autofilled-user";
    password.value = "autofilled-password";
    fireEvent.submit(username.form!);
    await waitFor(() =>
      expect(login).toHaveBeenCalledWith(
        "autofilled-user",
        "autofilled-password",
      ),
    );
  });
  it("associates both new-password fields with the account and submits autofilled values", async () => {
    const previous = api.user;
    api.user = {
      user_id: "admin",
      username: "admin",
      is_admin: true,
      must_change_password: true,
    };
    try {
      const change = vi.spyOn(api, "change").mockResolvedValue();
      render(<SignIn change />);
      const username = screen.getByLabelText("用户名") as HTMLInputElement;
      const old = screen.getByLabelText("当前密码") as HTMLInputElement;
      const password = screen.getByLabelText(
        "新密码 · 至少 12 个字符",
      ) as HTMLInputElement;
      const repeat = screen.getByLabelText(
        "再次输入新密码",
      ) as HTMLInputElement;
      expect(username.value).toBe("admin");
      expect(username.readOnly).toBe(true);
      expect(username.autocomplete).toBe("username");
      expect(old.autocomplete).toBe("current-password");
      expect(password.autocomplete).toBe("new-password");
      expect(repeat.autocomplete).toBe("new-password");
      expect(password.form).toBe(username.form);
      expect(repeat.form).toBe(username.form);
      expect(password.name).not.toBe(repeat.name);
      old.value = "admin";
      password.value = repeat.value = "generated-password-123";
      fireEvent.submit(password.form!);
      await waitFor(() =>
        expect(change).toHaveBeenCalledWith("admin", "generated-password-123"),
      );
    } finally {
      api.user = previous;
    }
  });
  it("blocks mismatched passwords before requesting a forced password change", async () => {
    const change = vi.spyOn(api, "change").mockResolvedValue();
    const done = vi.fn();
    render(<SignIn change onDone={done} />);
    fireEvent.change(screen.getByLabelText("当前密码"), {
      target: { value: "admin" },
    });
    fireEvent.change(screen.getByLabelText("新密码 · 至少 12 个字符"), {
      target: { value: "new-password-123" },
    });
    fireEvent.change(screen.getByLabelText("再次输入新密码"), {
      target: { value: "different-password" },
    });
    fireEvent.click(screen.getByRole("button", { name: "修改密码" }));
    expect(await screen.findByRole("alert")).toHaveProperty(
      "textContent",
      "两次新密码不一致",
    );
    expect(change).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText("再次输入新密码"), {
      target: { value: "new-password-123" },
    });
    fireEvent.click(screen.getByRole("button", { name: "修改密码" }));
    await waitFor(() => expect(done).toHaveBeenCalled());
    expect(change).toHaveBeenCalledWith("admin", "new-password-123");
  });
  it("sorts receipt columns through the API and distinguishes draft and failure rows", async () => {
    const rows = [
      {
        receipt_id: "draft",
        raw_store: "Draft store",
        status: "draft",
        created_at_utc_ms: 1,
        occurred_at_utc_ms: 2,
        currency_code: "USD",
        total_minor: 100,
        version: 1,
      },
      {
        receipt_id: "failed",
        raw_store: "Failed store",
        status: "draft",
        recognition_status: "failed",
        created_at_utc_ms: 3,
        occurred_at_utc_ms: 4,
        currency_code: "USD",
        total_minor: 200,
        version: 1,
      },
    ];
    const op = vi
      .spyOn(api, "op")
      .mockImplementation(async (_component, _operation, input) => ({
        items: input?.cursor ? rows.slice(1) : rows.slice(0, 1),
        next_cursor: input?.cursor ? null : "next-page",
      }));
    const open = vi.fn();
    render(<Receipts open={open} product={null} />);
    await screen.findByText("Draft store");
    expect(screen.getByText("共 2 张收据")).toBeTruthy();
    expect(op.mock.calls[0][2]).toMatchObject({
      sort_by: "created_at",
      direction: "desc",
    });
    fireEvent.click(screen.getByRole("button", { name: /录入时间/ }));
    await waitFor(() =>
      expect(op.mock.calls.at(-1)?.[2]).toMatchObject({
        sort_by: "created_at",
        direction: "asc",
      }),
    );
    fireEvent.click(screen.getByRole("button", { name: /店名/ }));
    await waitFor(() =>
      expect(op.mock.calls.at(-1)?.[2]).toMatchObject({
        sort_by: "store",
        direction: "asc",
      }),
    );
    fireEvent.click(screen.getByText("Draft store"));
    expect(open).toHaveBeenCalledWith("draft");
    expect(screen.getByText("Draft store").closest("tr")?.className).toContain(
      "draft",
    );
    expect(screen.getByText("Failed store").closest("tr")?.className).toContain(
      "failed",
    );
    op.mockRejectedValue(new Error("Timeout"));
    fireEvent.click(screen.getByRole("button", { name: "刷新收据" }));
    await screen.findByText("Timeout");
    expect(screen.getByText("共 2 张收据")).toBeTruthy();
    op.mockResolvedValue({ items: [], next_cursor: null });
    fireEvent.click(screen.getByRole("button", { name: "刷新收据" }));
    await screen.findByText("共 0 张收据");
  });
  it("supports keyboard chart selection and optional category curves", () => {
    const select = vi.fn();
    const data = {
      currency: "USD",
      points: [
        { start: 1, label: "January", tick: "Jan", net: 100 },
        { start: 2, label: "February", tick: "Feb", net: 250 },
      ],
      series: [{ key: "category", label: "水果", values: [50, 100] }],
    };
    const { container, rerender } = render(
      <TrendChart
        data={data}
        visible={new Set(["total"])}
        index={1}
        onSelect={select}
      />,
    );
    expect(container.querySelectorAll("polyline")).toHaveLength(1);
    fireEvent.keyDown(screen.getByRole("button", { name: /January/ }), {
      key: "Enter",
    });
    expect(select).toHaveBeenCalledWith(0);
    rerender(
      <TrendChart
        data={data}
        visible={new Set(["total", "category"])}
        index={0}
        onSelect={select}
      />,
    );
    expect(container.querySelectorAll("polyline")).toHaveLength(2);
  });
  it("selects an item discount's target and lets the backend prepare amounts", async () => {
    HTMLDialogElement.prototype.showModal = function () {
      this.open = true;
    };
    HTMLDialogElement.prototype.close = vi.fn();
    const line = { ...emptyLine(), kind: "item_discount", rawName: "Discount" };
    const op = vi
      .spyOn(api, "op")
      .mockImplementation(async (_component, operation, input) =>
        operation === "list" ? [] : input?.line,
      );
    const save = vi.fn();
    render(
      <LineEditor
        line={line}
        lines={[{ id: "product", kind: "product", rawName: "Milk" }]}
        currency="USD"
        categories={[]}
        receiptTypes={[]}
        onSave={save}
        onClose={() => {}}
      />,
    );
    expect(screen.getByLabelText("税码")).toHaveProperty("maxLength", 3);
    fireEvent.change(screen.getByLabelText("税码"), {
      target: { value: "ABC" },
    });
    fireEvent.change(screen.getByLabelText("折扣对应商品"), {
      target: { value: "product" },
    });
    fireEvent.change(screen.getByLabelText("金额 (USD)"), {
      target: { value: "-1.20" },
    });
    fireEvent.click(screen.getByRole("button", { name: "应用修改" }));
    await waitFor(() => expect(save).toHaveBeenCalled());
    expect(op.mock.calls.at(-1)?.[2]).toMatchObject({
      line: { discountTarget: "product", taxCode: "ABC" },
      fields: { amountText: "-1.20" },
    });
  });
});

describe("confirmed receipts and admin management", () => {
  it("saves edits to confirmed receipts without accidentally downgrading them", async () => {
    const { Editor } = await import("../../src/web/src/main");
    const r = {
      id: "confirmed",
      store: "Store",
      country: "US",
      branch: "",
      address: "",
      currency: "USD",
      posted: true,
      occurredAt: 1780000000000,
      timeSource: "user_entered",
      totalMinor: 100,
      revision: 1,
      lines: [],
    };
    const op = vi
      .spyOn(api, "op")
      .mockImplementation(async (component, operation, input) => {
        if (operation === "get") return r;
        if (operation === "list") return [];
        if (operation === "edit")
          return {
            ...input?.receipt,
            summary: { knownTotal: 100, difference: 0 },
          };
        if (operation === "check_duplicates") return [];
        return r;
      });
    render(<Editor id="confirmed" isNew={false} onBack={() => {}} />);
    await screen.findByDisplayValue("Store");
    fireEvent.change(screen.getByLabelText("店铺名称"), {
      target: { value: "Corrected Store" },
    });
    fireEvent.click(screen.getByRole("button", { name: "录入并退出" }));
    await waitFor(() =>
      expect(op.mock.calls.some((c) => c[1] === "confirm")).toBe(true),
    );
    expect(op.mock.calls.some((c) => c[1] === "save")).toBe(false);
    expect(op.mock.calls.find((c) => c[1] === "confirm")?.[2]).toMatchObject({
      receipt: { store: "Corrected Store" },
    });
  });
  it("provides deletion controls only for ordinary accounts", async () => {
    const { Users } = await import("../../src/web/src/main");
    vi.spyOn(api, "auth").mockResolvedValue([
      {
        user_id: "admin",
        username: "admin",
        is_admin: true,
        must_change_password: false,
      },
      {
        user_id: "bob",
        username: "bob",
        is_admin: false,
        must_change_password: true,
      },
    ]);
    render(<Users />);
    await screen.findByText("bob");
    expect(screen.getByRole("button", { name: "删除用户 bob" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "删除用户 admin" })).toBeNull();
  });
});
