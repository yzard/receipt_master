// @vitest-environment jsdom
import React from "react";
import { it, expect, vi, afterEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  waitFor,
  within,
  act,
} from "@testing-library/react";
import { App } from "../../src/web/src/main";
import { api, emptyReceipt } from "../../src/web/src/api";
vi.mock("../../src/web/src/uploads", () => ({
  pending: async () => [],
  retry: async () => {},
  enqueue: vi.fn(),
}));
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.useRealTimers();
});
it("keeps visited tabs and scroll positions behind editors, patches saves, and does not reload on return", async () => {
  const previous = api.user;
  const scroll = vi.spyOn(window, "scrollTo").mockImplementation(() => {});
  const scrollDescriptor = Object.getOwnPropertyDescriptor(window, "scrollY")!;
  HTMLDialogElement.prototype.showModal = function () {
    this.open = true;
  };
  HTMLDialogElement.prototype.close = function () {
    this.open = false;
  };
  vi.spyOn(api, "refresh").mockImplementation(async () => {
    api.user = {
      user_id: "navigation",
      username: "navigation",
      is_admin: false,
      must_change_password: false,
    };
    api.onUser(api.user);
  });
  let receipt = {
    ...emptyReceipt(),
    id: "receipt",
    store: "Original Store",
    totalMinor: 100,
    revision: 1,
    summary: { difference: 0 },
    lines: [],
  };
  const op = vi
    .spyOn(api, "op")
    .mockImplementation(async (component, operation, input) => {
      if (component === "receipts") {
        if (operation === "list")
          return {
            items: [
              {
                receipt_id: receipt.id,
                raw_store: receipt.store,
                currency_code: "USD",
                total_minor: 100,
                version: 1,
              },
            ],
            next_cursor: null,
          };
        if (operation === "get") return receipt;
        if (operation === "edit")
          return { ...input!.receipt, summary: { difference: 0 } };
        if (operation === "save") {
          receipt = { ...input!.receipt, revision: 2 };
          return receipt;
        }
      }
      return [];
    });
  const count = (component: string, operation: string) =>
    op.mock.calls.filter((c) => c[0] === component && c[1] === operation)
      .length;
  async function navigate(label: string) {
    fireEvent.click(screen.getByRole("button", { name: "打开导航菜单" }));
    fireEvent.click(screen.getByRole("button", { name: label }));
  }
  try {
    render(<App />);
    await screen.findByText("Original Store");
    const originalTab = document.querySelector('[data-page="receipts"]');
    Object.defineProperty(window, "scrollY", {
      value: 432,
      configurable: true,
    });
    await navigate("商品");
    const search = await screen.findByRole("textbox", { name: "搜索商品" });
    fireEvent.change(search, { target: { value: "saved search" } });
    const pageScroll = document.scrollingElement || document.documentElement;
    pageScroll.scrollTop = 300;
    fireEvent.click(screen.getByRole("tab", { name: "商品名称" }));
    expect(pageScroll.scrollTop).toBe(0);
    pageScroll.scrollTop = 150;
    fireEvent.click(screen.getByRole("tab", { name: "票据名称" }));
    expect(pageScroll.scrollTop).toBe(300);
    await navigate("收据");
    expect(document.querySelector('[data-page="receipts"]')).toBe(originalTab);
    expect(scroll).toHaveBeenLastCalledWith(0, 432);
    expect(count("receipts", "list")).toBe(1);
    await navigate("商品");
    expect(screen.getByRole("textbox", { name: "搜索商品" })).toBe(search);
    expect((search as HTMLInputElement).value).toBe("saved search");
    expect(count("printed_names", "list")).toBe(1);
    await navigate("店铺");
    fireEvent.click(await screen.findByRole("tab", { name: "店铺类别" }));
    await waitFor(() => expect(count("merchants", "list")).toBe(1));
    fireEvent.click(screen.getByRole("tab", { name: "店铺名称" }));
    fireEvent.click(screen.getByRole("tab", { name: "店铺类别" }));
    expect(count("merchants", "list")).toBe(1);
    await navigate("收据");
    fireEvent.click(screen.getByText("Original Store"));
    const overlay = await screen.findByRole("dialog", { name: "编辑收据" });
    expect(document.querySelector('[data-page="receipts"]')).toBe(originalTab);
    const store = await within(overlay).findByRole("textbox", {
      name: "店铺名称",
    });
    vi.useFakeTimers();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(15000);
    });
    expect(count("receipts", "list")).toBe(1);
    vi.useRealTimers();
    fireEvent.change(store, { target: { value: "Saved Store" } });
    fireEvent.click(within(overlay).getByRole("button", { name: "保存草稿" }));
    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: "编辑收据" })).toBeNull(),
    );
    expect(screen.getByText("Saved Store")).toBeTruthy();
    expect(count("receipts", "list")).toBe(1);
    fireEvent.click(screen.getByText("Saved Store"));
    const second = await screen.findByRole("dialog", { name: "编辑收据" });
    fireEvent.change(
      await within(second).findByRole("textbox", { name: "店铺名称" }),
      { target: { value: "Discarded Store" } },
    );
    fireEvent.click(within(second).getByRole("button", { name: "放弃改动" }));
    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: "编辑收据" })).toBeNull(),
    );
    expect(screen.getByText("Saved Store")).toBeTruthy();
    expect(screen.queryByText("Discarded Store")).toBeNull();
    expect(count("receipts", "list")).toBe(1);
    expect(count("receipts", "save")).toBe(1);
    expect(document.body.style.overflow).toBe("");
  } finally {
    cleanup();
    api.user = previous;
    Object.defineProperty(window, "scrollY", scrollDescriptor);
  }
});
