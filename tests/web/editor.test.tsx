// @vitest-environment jsdom
import React from "react";
import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  waitFor,
  within,
} from "@testing-library/react";
import { Editor, LineEditor } from "../../src/web/src/main";
import { api, emptyLine, emptyReceipt, Row } from "../../src/web/src/api";
vi.mock("../../src/web/src/uploads", () => ({
  pending: async () => [],
  retry: vi.fn(),
  enqueue: vi.fn(),
}));
beforeEach(() => {
  HTMLDialogElement.prototype.showModal = function () {
    this.open = true;
  };
  HTMLDialogElement.prototype.close = vi.fn();
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
function setup(
  options: { isNew?: boolean; receipt?: Row; difference?: number | null } = {},
) {
  const receipt = {
    ...emptyReceipt(),
    id: "receipt",
    store: "Store",
    revision: 3,
    timeSource: "user_entered",
    totalMinor: 100,
    lines: [{ ...emptyLine(), rawName: "Milk", amountMinor: 100 }],
    ...options.receipt,
  };
  const images = [{ image_id: "photo", media_id: "media" }];
  const op = vi
    .spyOn(api, "op")
    .mockImplementation(async (component, operation, input) => {
      if (operation === "get") return receipt;
      if (operation === "list") return component === "images" ? images : [];
      if (operation === "edit")
        return {
          ...input?.receipt,
          summary: {
            knownTotal: 100,
            difference:
              options.difference === undefined ? 0 : options.difference,
          },
        };
      if (operation === "check_duplicates") return [];
      return input?.receipt ?? receipt;
    });
  const back = vi.fn();
  const confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
  const view = render(
    <Editor id="receipt" isNew={options.isNew ?? false} onBack={back} />,
  );
  return { receipt, op, back, confirm, view };
}
function writes(op: ReturnType<typeof vi.spyOn>) {
  return op.mock.calls.filter((call: any[]) =>
    ["save", "confirm", "purge"].includes(call[1]),
  );
}
async function changeStore() {
  await screen.findByDisplayValue("Store");
  fireEvent.change(screen.getByLabelText("商店名称"), {
    target: { value: "Edited" },
  });
}
describe("explicit receipt editing", () => {
  it("keeps edits local across the former autosave interval and discards without writing", async () => {
    const { op, back, confirm } = setup();
    await changeStore();
    await new Promise((resolve) => setTimeout(resolve, 700));
    expect(writes(op)).toEqual([]);
    expect(op.mock.calls.some((c) => c[1] === "edit")).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "放弃改动" }));
    await waitFor(() => expect(back).toHaveBeenCalledOnce());
    expect(writes(op)).toEqual([]);
    expect(confirm).not.toHaveBeenCalled();
  });
  it("saves a draft only on explicit request and exits after success", async () => {
    const { op, back, confirm } = setup();
    await changeStore();
    fireEvent.click(screen.getByRole("button", { name: "保存草稿" }));
    await waitFor(() => expect(back).toHaveBeenCalledOnce());
    expect(writes(op)).toHaveLength(1);
    expect(op).toHaveBeenCalledWith("receipts", "save", {
      receipt: expect.objectContaining({ store: "Edited" }),
    });
    expect(confirm).not.toHaveBeenCalled();
  });
  it("requires an explicit discard or save on dirty back navigation", async () => {
    const { op, back } = setup();
    await changeStore();
    fireEvent.click(screen.getByRole("button", { name: "返回收据" }));
    const dialog = await screen.findByRole("dialog");
    expect(back).not.toHaveBeenCalled();
    expect(writes(op)).toEqual([]);
    fireEvent.click(within(dialog).getByRole("button", { name: "继续编辑" }));
    expect(screen.getByLabelText("商店名称")).toHaveProperty("value", "Edited");
    fireEvent.click(screen.getByRole("button", { name: "返回收据" }));
    fireEvent.click(
      within(await screen.findByRole("dialog")).getByRole("button", {
        name: "保存草稿",
      }),
    );
    await waitFor(() => expect(back).toHaveBeenCalledOnce());
    expect(writes(op)).toHaveLength(1);
  });
  it("removes only the empty manual placeholder when discarded", async () => {
    const { op, back } = setup({ isNew: true });
    await changeStore();
    fireEvent.click(screen.getByRole("button", { name: "放弃改动" }));
    await waitFor(() => expect(back).toHaveBeenCalledOnce());
    expect(op).toHaveBeenCalledWith("receipts", "purge", {
      id: "receipt",
      expected_version: 3,
    });
    expect(writes(op)).toHaveLength(1);
  });
  it("records a balanced receipt with no confirmation prompt", async () => {
    const { op, back, confirm } = setup();
    await changeStore();
    fireEvent.click(screen.getByRole("button", { name: "录入并退出" }));
    await waitFor(() => expect(back).toHaveBeenCalledOnce());
    expect(confirm).not.toHaveBeenCalled();
    expect(writes(op)[0][1]).toBe("confirm");
  });
  it("keeps the editor open when anomaly confirmation is declined", async () => {
    const { op, back, confirm } = setup({
      difference: 20,
      receipt: {
        timeSource: "estimated_clock",
        lines: [{ ...emptyLine(), rawName: "Milk", warnings: ["待核对"] }],
      },
    });
    confirm.mockReturnValue(false);
    await changeStore();
    fireEvent.click(screen.getByRole("button", { name: "录入并退出" }));
    await waitFor(() => expect(confirm).toHaveBeenCalled());
    expect(confirm.mock.calls[0][0]).toContain("0.20");
    expect(confirm.mock.calls[0][0]).toContain("有明细尚待核对");
    expect(confirm.mock.calls[0][0]).toContain("消费时间是估计值");
    expect(writes(op)).toEqual([]);
    expect(back).not.toHaveBeenCalled();
  });
  it("blocks recording when the difference cannot be calculated", async () => {
    const { op, back } = setup({ difference: null });
    await screen.findByDisplayValue("Store");
    fireEvent.click(screen.getByRole("button", { name: "录入并退出" }));
    expect(await screen.findByRole("alert")).toHaveProperty(
      "textContent",
      "无法计算收据差额，请重试",
    );
    expect(writes(op)).toEqual([]);
    expect(back).not.toHaveBeenCalled();
  });
  it("preserves local changes on save failure", async () => {
    const { op, back } = setup();
    const original = op.getMockImplementation()!;
    op.mockImplementation(async (...args) => {
      if (args[1] === "save") throw new Error("保存失败");
      return original(...args);
    });
    await changeStore();
    fireEvent.click(screen.getByRole("button", { name: "保存草稿" }));
    expect(await screen.findByRole("alert")).toHaveProperty(
      "textContent",
      "保存失败",
    );
    expect(screen.getByLabelText("商店名称")).toHaveProperty("value", "Edited");
    expect(back).not.toHaveBeenCalled();
  });
  it("retries recognition from the stored revision without saving local changes", async () => {
    const { op, back, confirm } = setup({ receipt: { posted: true } });
    await changeStore();
    fireEvent.click(screen.getByRole("button", { name: "重新识别" }));
    await waitFor(() => expect(back).toHaveBeenCalledOnce());
    expect(confirm.mock.calls[0][0]).toContain("放弃未保存修改");
    expect(writes(op)).toEqual([]);
    expect(op).toHaveBeenCalledWith(
      "recognition",
      "start",
      expect.objectContaining({ expected_version: 3 }),
    );
  });
  it("does not save or lose field changes during explicit photo actions", async () => {
    const { op } = setup();
    await changeStore();
    fireEvent.click(screen.getByRole("button", { name: "旋转照片" }));
    await waitFor(() =>
      expect(op).toHaveBeenCalledWith("images", "rotate", expect.anything()),
    );
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: "旋转照片" }),
      ).not.toHaveProperty("disabled", true),
    );
    expect(screen.getByLabelText("商店名称")).toHaveProperty("value", "Edited");
    expect(writes(op)).toEqual([]);
  });
  it("shows product name before printed name in the item form", async () => {
    const line = { ...emptyLine(), rawName: "Printed milk" };
    vi.spyOn(api, "op").mockResolvedValue([]);
    render(
      <LineEditor
        line={line}
        lines={[line]}
        currency="USD"
        categories={[]}
        onClose={() => {}}
        onSave={() => {}}
      />,
    );
    const inputs = screen.getByRole("dialog").querySelectorAll("input");
    expect(inputs[0]).toBe(screen.getByLabelText("商品名称"));
    expect(inputs[1]).toBe(screen.getByLabelText("票面名称"));
  });
});
