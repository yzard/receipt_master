// @vitest-environment jsdom
import React from "react";
import { afterEach, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { Reports, TrendChart, TrendSeriesMenu } from "../../src/web/src/main";
import { api } from "../../src/web/src/api";
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
const series = [
  {
    key: "category:drinks",
    group: "category",
    label: "饮料",
    values: [100],
    category_keys: [],
  },
  {
    key: "product:water",
    group: "product",
    label: "瓶装水",
    values: [100],
    category_keys: ["category:drinks"],
  },
];
const data = {
  currency: "USD",
  points: [{ start: 1, end: 2, label: "当前周期", tick: "Jan", net: 100 }],
  series,
};
it("nests classified products under their categories and lets users select either curve", () => {
  const toggle = vi.fn();
  render(
    <TrendSeriesMenu series={series} visible={new Set()} onToggle={toggle} />,
  );
  const drinks = screen.getByRole("region", { name: "饮料" });
  expect(within(drinks).queryByRole("checkbox", { name: /瓶装水/ })).toBeNull();
  const expand = within(drinks).getByRole("button", { name: "展开饮料商品" });
  expect(expand.getAttribute("aria-expanded")).toBe("false");
  fireEvent.click(expand);
  expect(toggle).not.toHaveBeenCalled();
  expect(within(drinks).getByRole("checkbox", { name: /瓶装水/ })).toBeTruthy();
  fireEvent.click(within(drinks).getByRole("checkbox", { name: /瓶装水/ }));
  expect(toggle).toHaveBeenCalledWith("product:water");
  fireEvent.click(within(drinks).getByRole("button", { name: "收起饮料商品" }));
  expect(within(drinks).queryByRole("checkbox", { name: /瓶装水/ })).toBeNull();
  expect(toggle).toHaveBeenCalledTimes(1);
});
it("shows a matching legend and preserves a product's color when other lines are toggled", () => {
  const view = render(
    <TrendChart
      data={data}
      visible={new Set(["total", "category:drinks", "product:water"])}
      index={0}
      onSelect={vi.fn()}
    />,
  );
  const legend = screen.getByRole("list", { name: "图例" });
  expect(within(legend).getByText("商品分类 · 饮料")).toBeTruthy();
  const swatch = within(legend)
    .getByText("商品 · 瓶装水")
    .querySelector("span")! as HTMLElement;
  const color = view.container
    .querySelectorAll("polyline")[2]
    .getAttribute("stroke");
  const probe = document.createElement("span");
  probe.style.backgroundColor = color!;
  expect(swatch.style.backgroundColor).toBe(probe.style.backgroundColor);
  view.rerender(
    <TrendChart
      data={data}
      visible={new Set(["product:water"])}
      index={0}
      onSelect={vi.fn()}
    />,
  );
  expect(view.container.querySelector("polyline")?.getAttribute("stroke")).toBe(
    color,
  );
  expect(screen.queryByText("商品分类 · 饮料")).toBeNull();
  expect(screen.getByText("商品 · 瓶装水")).toBeTruthy();
});
it("queries again when opening curve selection, refreshing, or returning to the page", async () => {
  let classified = false,
    trends = 0,
    summaries = 0;
  const op = vi
    .spyOn(api, "op")
    .mockImplementation(async (component, action) => {
      if (component === "categories") return [];
      if (action === "trend") {
        trends++;
        const category = classified ? "drinks" : "uncategorized";
        return {
          ...data,
          series: [
            {
              ...series[0],
              key: `category:${category}`,
              label: classified ? "饮料" : "未分类",
            },
            { ...series[1], category_keys: [`category:${category}`] },
          ],
        };
      }
      summaries++;
      return {
        currency: "USD",
        net: 100,
        discounts: 0,
        refunds: 0,
        difference: 0,
        groups: [],
        entries: [],
        next_offset: null,
      };
    });
  render(<Reports open={vi.fn()} />);
  await waitFor(() => expect(summaries).toBe(1));
  classified = true;
  fireEvent.click(screen.getByRole("button", { name: "曲线选择" }));
  await screen.findByRole("region", { name: "饮料" });
  expect(screen.queryByRole("region", { name: "未分类" })).toBeNull();
  await waitFor(() => expect(summaries).toBe(2));
  expect(trends).toBe(2);
  fireEvent.click(screen.getByRole("button", { name: "重新统计并刷新报表" }));
  await waitFor(() => expect(summaries).toBe(3));
  fireEvent(window, new Event("focus"));
  await waitFor(() => expect(summaries).toBe(4));
  expect(op.mock.calls.filter((call) => call[1] === "trend")).toHaveLength(4);
});

it("keeps empty categories disabled and child categories independently selectable", () => {
  const toggle = vi.fn();
  const allSeries = [
    {
      key: "category:uncategorized",
      group: "category",
      label: "未分类",
      values: [0],
      category_keys: [],
    },
    {
      key: "category:groceries",
      group: "category",
      label: "杂货",
      values: [100],
      category_keys: [],
    },
    { ...series[0], depth: 1, path: "杂货 / 饮料" },
    {
      key: "category:nuts",
      group: "category",
      label: "坚果",
      values: [0],
      category_keys: [],
    },
    {
      key: "category:refunded",
      group: "category",
      label: "已退商品",
      values: [0],
      has_activity: true,
      category_keys: [],
    },
    series[1],
  ];
  render(
    <TrendSeriesMenu
      series={allSeries}
      visible={new Set(["category:drinks"])}
      onToggle={toggle}
    />,
  );
  const groceries = within(
    screen.getByRole("region", { name: "杂货" }),
  ).getByRole("checkbox");
  const drinks = within(screen.getByRole("region", { name: "饮料" })).getByRole(
    "checkbox",
    { name: /^饮料/ },
  );
  const nuts = within(screen.getByRole("region", { name: "坚果" })).getByRole(
    "checkbox",
  );
  fireEvent.click(screen.getByRole("button", { name: "展开饮料商品" }));
  const water = screen.getByRole("checkbox", { name: /瓶装水/ });
  expect((drinks as HTMLInputElement).checked).toBe(true);
  expect((groceries as HTMLInputElement).checked).toBe(false);
  expect((water as HTMLInputElement).checked).toBe(false);
  expect((nuts as HTMLInputElement).disabled).toBe(true);
  expect(
    (screen.getByRole("checkbox", { name: /已退商品/ }) as HTMLInputElement)
      .disabled,
  ).toBe(false);
  expect(
    screen.getByRole("checkbox", { name: /未分类/ }).hasAttribute("disabled"),
  ).toBe(true);
  fireEvent.click(groceries);
  expect(toggle.mock.calls).toEqual([["category:groceries"]]);
  expect((water as HTMLInputElement).checked).toBe(false);
});

it("shows every category heading before expanding any of a large product catalogue", () => {
  const many = Array.from({ length: 30 }, (_, i) => ({
    key: `category:${i}`,
    group: "category",
    label: `分类 ${i + 1}`,
    values: [100],
    category_keys: [],
  }));
  const products = Array.from({ length: 80 }, (_, i) => ({
    key: `product:${i}`,
    group: "product",
    label: `商品 ${i + 1}`,
    values: [100],
    category_keys: ["category:0"],
  }));
  render(
    <TrendSeriesMenu
      series={[...many, ...products]}
      visible={new Set()}
      onToggle={vi.fn()}
    />,
  );
  expect(screen.getAllByRole("region")).toHaveLength(30);
  expect(screen.getByRole("checkbox", { name: /分类 30/ })).toBeTruthy();
  expect(screen.queryByRole("checkbox", { name: /^商品 1商品$/ })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "展开分类 1商品" }));
  expect(screen.getByRole("checkbox", { name: /^商品 1商品$/ })).toBeTruthy();
  expect(screen.getByRole("checkbox", { name: /分类 30/ })).toBeTruthy();
});
