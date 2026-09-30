// @vitest-environment jsdom
import React from "react";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CatalogSearchInput } from "../../src/web/src/catalog-search";
import { api } from "../../src/web/src/api";
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
describe("database catalog suggestions", () => {
  it.each(["product_names", "categories"] as const)(
    "queries %typed% for %s and selects without creating records",
    async (component) => {
      const op = vi.spyOn(api, "op").mockResolvedValue([
        {
          name: "瓶装水",
          product_name_id: "water",
          category_id: "water-category",
        },
      ]);
      function Example() {
        const [value, setValue] = React.useState("");
        return (
          <CatalogSearchInput
            label="名称"
            component={component}
            value={value}
            onChange={setValue}
          />
        );
      }
      render(<Example />);
      const input = screen.getByRole("combobox");
      fireEvent.focus(input);
      fireEvent.change(input, { target: { value: "装" } });
      fireEvent.change(input, { target: { value: "装水" } });
      await screen.findByRole("option", { name: "瓶装水" });
      expect(op).toHaveBeenCalledExactlyOnceWith(component, "suggest", {
        query: "装水",
      });
      fireEvent.keyDown(input, { key: "ArrowDown" });
      fireEvent.keyDown(input, { key: "Enter" });
      expect((input as HTMLInputElement).value).toBe("瓶装水");
      expect(screen.queryByRole("option")).toBeNull();
    },
  );
  it("ignores stale replies and allows a new name after search fails", async () => {
    let finish!: (value: any) => void;
    const op = vi
      .spyOn(api, "op")
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            finish = resolve;
          }),
      )
      .mockRejectedValue(new Error("offline"));
    function Example() {
      const [value, setValue] = React.useState("");
      return (
        <CatalogSearchInput
          label="名称"
          component="product_names"
          value={value}
          onChange={setValue}
        />
      );
    }
    render(<Example />);
    const input = screen.getByRole("combobox");
    fireEvent.focus(input);
    fireEvent.change(input, { target: { value: "old" } });
    await waitFor(() => expect(op).toHaveBeenCalledTimes(1));
    fireEvent.change(input, { target: { value: "新名称" } });
    finish([{ product_name_id: "old", name: "旧结果" }]);
    await screen.findByRole("status");
    expect(screen.queryByRole("option")).toBeNull();
    expect((input as HTMLInputElement).value).toBe("新名称");
  });
});

it("warns when reusing a product name and rejects duplicate new categories", async () => {
  vi.spyOn(api, "op").mockResolvedValue([
    {
      name: "Water",
      product_name_id: "water",
      category_id: "kind",
      exact_match: true,
    },
  ]);
  const change = vi.fn();
  const view = render(
    <CatalogSearchInput
      label="名称"
      component="product_names"
      value="water"
      onChange={change}
    />,
  );
  fireEvent.focus(screen.getByRole("combobox"));
  await screen.findByText("已有同名记录，将使用已有名称，不会重复添加");
  expect(
    (screen.getByRole("combobox") as HTMLInputElement).checkValidity(),
  ).toBe(true);
  view.rerender(
    <CatalogSearchInput
      label="名称"
      component="categories"
      value="water"
      onChange={change}
      rejectExistingName
    />,
  );
  await screen.findByText("商品种类名称已存在，请使用其他名称");
  expect(
    (screen.getByRole("combobox") as HTMLInputElement).checkValidity(),
  ).toBe(false);
  view.rerender(
    <CatalogSearchInput
      label="名称"
      component="categories"
      value="water"
      onChange={change}
      rejectExistingName
      currentId="water"
    />,
  );
  expect(
    (screen.getByRole("combobox") as HTMLInputElement).checkValidity(),
  ).toBe(true);
});
