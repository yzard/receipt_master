// @vitest-environment jsdom
import React from "react";
import { readFileSync } from "node:fs";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  waitFor,
  act,
} from "@testing-library/react";
import { App, SignIn, LineEditor } from "../../src/web/src/main";
import { api, emptyLine } from "../../src/web/src/api";
import {
  availableLanguages,
  getLanguage,
  installTranslations,
  loadTranslations,
  message,
  setLanguage,
  tr,
} from "../../src/web/src/i18n";

vi.mock("../../src/web/src/uploads", () => ({
  pending: async () => [],
  retry: vi.fn(async () => {}),
  enqueue: vi.fn(),
}));
function resource() {
  return JSON.parse(
    readFileSync("../backend_api/resources/localizations.json", "utf8"),
  );
}
beforeEach(() => {
  installTranslations(resource());
  setLanguage("zh");
  HTMLDialogElement.prototype.showModal = function () {
    this.open = true;
  };
  HTMLDialogElement.prototype.close = vi.fn();
});
afterEach(() => {
  cleanup();
  setLanguage("zh");
  localStorage.clear();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
describe("backend-owned interface languages", () => {
  it("loads all translations once and offers exactly the server's available languages", async () => {
    const data = resource();
    data.available_languages.push({
      code: "fr",
      name: "Français",
      locale: "fr-FR",
    });
    data.translations.fr = { ...data.translations.en, 设置: "Paramètres" };
    const fetch = vi.fn(
      async () => new Response(JSON.stringify({ data }), { status: 200 }),
    );
    vi.stubGlobal("fetch", fetch);
    await Promise.all([loadTranslations(), loadTranslations()]);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(fetch.mock.calls[0]).toMatchObject([
      "/api/v1/localizations/get",
      { method: "POST", credentials: "omit" },
    ]);
    const previous = api.user;
    vi.spyOn(api, "refresh").mockImplementation(async () => {
      api.user = {
        user_id: "language-user",
        username: "language-user",
        is_admin: true,
        must_change_password: false,
      };
      api.onUser(api.user);
    });
    const op = vi
      .spyOn(api, "op")
      .mockImplementation(async (component) =>
        component === "receipts"
          ? { items: [], next_cursor: null }
          : { weight_unit: "kg", report_currency: "USD" },
      );
    try {
      const app = render(<App />);
      fireEvent.click(
        await screen.findByRole("button", { name: "打开导航菜单" }),
      );
      fireEvent.click(screen.getByRole("button", { name: "设置" }));
      await screen.findByLabelText("全局重量显示单位");
      const requests = op.mock.calls.length;
      const language = screen.getByLabelText("Language");
      expect(
        Array.from((language as HTMLSelectElement).options).map(
          (entry) => entry.value,
        ),
      ).toEqual(["zh", "en", "fr"]);
      fireEvent.change(language, { target: { value: "en" } });
      expect(
        await screen.findByRole("heading", { name: "Settings" }),
      ).toBeTruthy();
      expect(localStorage.getItem("language")).toBe("en");
      expect(document.documentElement.lang).toBe("en-US");
      fireEvent.click(
        screen.getByRole("button", { name: "Open navigation menu" }),
      );
      expect(screen.getByRole("button", { name: "Reports" })).toBeTruthy();
      expect(screen.getByRole("button", { name: "Stores" })).toBeTruthy();
      fireEvent.click(
        screen.getByRole("button", { name: "Close navigation menu" }),
      );
      fireEvent.change(language, { target: { value: "fr" } });
      expect(
        await screen.findByRole("heading", { name: "Paramètres" }),
      ).toBeTruthy();
      expect(document.documentElement.lang).toBe("fr-FR");
      expect(op.mock.calls.length).toBe(requests);
      expect(fetch).toHaveBeenCalledTimes(1);
      app.unmount();
      render(<SignIn />);
      expect(screen.getByLabelText("Username")).toBeTruthy();
      expect(getLanguage()).toBe("fr");
    } finally {
      api.user = previous;
    }
  });

  it("switches editable labels without changing names, unsaved values or autofill", async () => {
    render(
      <LineEditor
        line={{ ...emptyLine(), rawName: "牛奶", productNameEdit: "瓶装牛奶" }}
        lines={[]}
        currency="USD"
        categories={[]}
        receiptTypes={[]}
        onSave={vi.fn()}
        onClose={vi.fn()}
      />,
    );
    fireEvent.change(screen.getByLabelText("票面名称"), {
      target: { value: "未保存的票面名" },
    });
    await act(async () => setLanguage("en"));
    expect(
      (screen.getByLabelText("Printed name") as HTMLInputElement).value,
    ).toBe("未保存的票面名");
    expect(
      (screen.getByLabelText("Product name") as HTMLInputElement).value,
    ).toBe("瓶装牛奶");
    cleanup();
    render(<SignIn change />);
    expect(
      screen
        .getByLabelText("New password · at least 12 characters")
        .getAttribute("autocomplete"),
    ).toBe("new-password");
    expect(
      screen
        .getByLabelText("Confirm new password")
        .getAttribute("autocomplete"),
    ).toBe("new-password");
  });

  it("translates known errors and parameters while preserving unknown notes", () => {
    setLanguage("en");
    expect(message("用户名或密码不正确")).toBe(
      "Incorrect username or password",
    );
    expect(
      message(
        "称重金额不符：计算 USD 8.40，票面 USD 9.40，差额 USD +1.00（票面−计算）",
      ),
    ).toContain("USD +1.00");
    expect(message("自定义模型备注：商品名字")).toBe(
      "自定义模型备注：商品名字",
    );
    expect(tr("商品 · {0}", ["商品"])).toBe("Product · 商品");
    const before = availableLanguages();
    expect(() =>
      installTranslations({
        schema_version: 1,
        available_languages: [],
        translations: {},
      }),
    ).toThrow();
    expect(availableLanguages()).toBe(before);
    expect(() => setLanguage("not-available")).toThrow();
  });

  it("uses a validated offline cache and retries a failed resource fetch", async () => {
    localStorage.setItem("localizations", JSON.stringify(resource()));
    localStorage.setItem("language", "en");
    vi.resetModules();
    const cached = await import("../../src/web/src/i18n");
    expect(cached.availableLanguages().map((entry) => entry.code)).toEqual([
      "zh",
      "en",
    ]);
    expect(cached.tr("设置")).toBe("Settings");
    const fetch = vi.fn((): Promise<Response> => {
      throw new Error("offline");
    });
    vi.stubGlobal("fetch", fetch);
    await expect(cached.loadTranslations()).rejects.toThrow("offline");
    expect(cached.tr("设置")).toBe("Settings");
    fetch.mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify({ data: resource() }))),
    );
    await Promise.all([cached.loadTranslations(), cached.loadTranslations()]);
    expect(fetch).toHaveBeenCalledTimes(2);
    expect(cached.translationError()).toBe("");

    localStorage.setItem("localizations", '{"schema_version":1}');
    vi.resetModules();
    const invalidCache = await import("../../src/web/src/i18n");
    expect(invalidCache.availableLanguages()).toEqual([]);
    expect(invalidCache.tr("设置")).toBe("设置");
    await invalidCache.loadTranslations();
    expect(invalidCache.tr("设置")).toBe("Settings");
  });
});
