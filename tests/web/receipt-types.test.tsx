// @vitest-environment jsdom
import React from "react";
import { afterEach, it, expect, vi } from "vitest";
import {
  render,
  screen,
  fireEvent,
  waitFor,
  cleanup,
} from "@testing-library/react";
import { ReceiptTypesManager } from "../../src/web/src/receipt_types";
import {
  Stores,
  Reports,
  TrendSeriesMenu,
  TrendChart,
} from "../../src/web/src/main";
import { api } from "../../src/web/src/api";
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
const types = [
  { receipt_type_id: "grocery", name: "杂货" },
  { receipt_type_id: "restaurant", name: "餐馆" },
  { receipt_type_id: "unknown", name: "未分类", system_key: "uncategorized" },
];
it("binds store defaults and handles duplicate errors without writing any receipt", async () => {
  let kind = "grocery";
  const op = vi
    .spyOn(api, "op")
    .mockImplementation(async (component, operation, input) => {
      if (operation === "list")
        return component === "receipt_types"
          ? types
          : [{ merchant_id: "store", name: "Costco", receipt_type_id: kind }];
      if (operation === "classify") {
        kind = input!.receipt_type_id;
        return null;
      }
      throw new Error("店铺类别已存在，请选择已有类别");
    });
  render(<ReceiptTypesManager />);
  const select = await screen.findByRole("combobox", {
    name: "Costco的店铺类别",
  });
  fireEvent.change(select, { target: { value: "restaurant" } });
  await waitFor(() =>
    expect((select as HTMLSelectElement).value).toBe("restaurant"),
  );
  expect(op.mock.calls.find((c) => c[1] === "classify")?.[2]).toMatchObject({
    id: "store",
    receipt_type_id: "restaurant",
  });
  fireEvent.click(screen.getByRole("button", { name: "添加店铺类别" }));
  fireEvent.change(screen.getByLabelText("店铺类别名称"), {
    target: { value: "杂货" },
  });
  fireEvent.click(screen.getByRole("button", { name: "保存类别" }));
  expect(await screen.findByRole("alert")).toHaveProperty(
    "textContent",
    expect.stringContaining("店铺类别已存在"),
  );
  expect(op.mock.calls.some((c) => c[0] === "receipts")).toBe(false);
});
it("filters both summaries and trends by receipt type and exposes its own curve and legend", async () => {
  const row = {
    key: "receipt_type:restaurant",
    label: "餐馆",
    group: "receipt_type",
    values: [100],
    has_activity: true,
    category_keys: [],
  };
  const trend = {
    currency: "USD",
    points: [{ start: 1, end: 2, tick: "Jan", label: "Jan", net: 100 }],
    series: [row],
  };
  const op = vi
    .spyOn(api, "op")
    .mockImplementation(async (component, operation) => {
      if (component === "categories") return [];
      if (operation === "trend") return trend;
      return {
        currency: "USD",
        net: 100,
        spend: 100,
        discounts: 0,
        refunds: 0,
        difference: 0,
        groups: [],
        entries: [],
        next_offset: null,
      };
    });
  const view = render(<Reports open={vi.fn()} />);
  const range = await screen.findByLabelText("店铺类别统计范围");
  fireEvent.change(range, { target: { value: "restaurant" } });
  await waitFor(() =>
    expect(
      op.mock.calls.some(
        (c) => c[1] === "summary" && c[2]?.receipt_type === "restaurant",
      ),
    ).toBe(true),
  );
  expect(
    op.mock.calls.some(
      (c) => c[1] === "trend" && c[2]?.receipt_type === "restaurant",
    ),
  ).toBe(true);
  view.unmount();
  const toggle = vi.fn();
  const menu = render(
    <TrendSeriesMenu series={[row]} visible={new Set()} onToggle={toggle} />,
  );
  fireEvent.click(screen.getByRole("checkbox", { name: /餐馆/ }));
  expect(toggle).toHaveBeenCalledWith(row.key);
  menu.unmount();
  render(
    <TrendChart
      data={trend}
      visible={new Set([row.key])}
      index={0}
      onSelect={vi.fn()}
    />,
  );
  expect(screen.getByText("店铺类别 · 餐馆")).toBeTruthy();
});

it("places name samples and store types in separate tabs on the stores page", async () => {
  const op = vi
    .spyOn(api, "op")
    .mockImplementation(async (component) =>
      component === "receipt_types" ? types : [],
    );
  render(<Stores />);
  expect(screen.getByRole("heading", { name: "店铺" })).toBeTruthy();
  expect(
    screen.getByRole("tab", { name: "店铺名称" }).getAttribute("aria-selected"),
  ).toBe("true");
  expect(screen.queryByRole("button", { name: "添加店铺类别" })).toBeNull();
  fireEvent.click(screen.getByRole("tab", { name: "店铺类别" }));
  expect(
    await screen.findByRole("button", { name: "添加店铺类别" }),
  ).toBeTruthy();
  expect(op.mock.calls.some((c) => c[0] === "merchants")).toBe(true);
  fireEvent.click(screen.getByRole("tab", { name: "店铺名称" }));
  expect(screen.queryByRole("button", { name: "添加店铺类别" })).toBeNull();
});
