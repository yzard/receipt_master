import { useSyncExternalStore } from "react";

export type Language = string;
export type AvailableLanguage = { code: string; name: string; locale: string };
export type TranslationCatalog = {
  schema_version: number;
  default_language: string;
  available_languages: AvailableLanguage[];
  translations: Record<string, Record<string, string>>;
};
const listeners = new Set<() => void>();
let catalog: TranslationCatalog | null = null;
let revision = 0;
let request: Promise<void> | null = null;
let loadError = "";
let patterns: { key: string; regex: RegExp }[] = [];
const localeCode = /^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/;

function savedLanguage(): string {
  try {
    const value = localStorage.getItem("language");
    return value && localeCode.test(value) ? value : "zh";
  } catch {
    return "zh";
  }
}
let language = savedLanguage();
export function getLanguage() {
  return language;
}
export function availableLanguages() {
  return catalog?.available_languages ?? [];
}
export function translationError() {
  return loadError;
}
function snapshot() {
  return `${revision}:${language}`;
}
function changed() {
  revision++;
  document.documentElement.lang = formatLocale();
  listeners.forEach((listener) => listener());
}
export function setLanguage(value: string) {
  if (!availableLanguages().some((entry) => entry.code === value))
    throw new Error("Unsupported language");
  localStorage.setItem("language", value);
  language = value;
  changed();
}

export function validateCatalog(value: unknown): TranslationCatalog {
  const input = value as TranslationCatalog;
  if (
    !input ||
    input.schema_version !== 1 ||
    !Array.isArray(input.available_languages) ||
    !input.available_languages.length ||
    !input.translations ||
    typeof input.translations !== "object"
  )
    throw new Error("翻译资源无效");
  const codes = new Set<string>();
  for (const entry of input.available_languages) {
    if (
      !entry ||
      !localeCode.test(entry.code) ||
      codes.has(entry.code) ||
      typeof entry.name !== "string" ||
      !entry.name ||
      !localeCode.test(entry.locale) ||
      !input.translations[entry.code] ||
      typeof input.translations[entry.code] !== "object" ||
      !Object.entries(input.translations[entry.code]).length ||
      Object.entries(input.translations[entry.code]).some(
        ([key, text]) => !key || typeof text !== "string",
      )
    )
      throw new Error("翻译资源无效");
    codes.add(entry.code);
  }
  if (!codes.has(input.default_language)) throw new Error("翻译资源无效");
  return input;
}
const escape = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
export function installTranslations(value: unknown) {
  const next = validateCatalog(value);
  catalog = next;
  if (!next.available_languages.some((entry) => entry.code === language))
    language = next.default_language;
  patterns = Object.keys(next.translations[next.default_language])
    .filter(
      (key) =>
        key.includes("{0}") &&
        /错误|不符|差额|相差|失败|无法|缺少|缺失|重复|无效|不存在|上传|下载|后端/.test(
          key,
        ),
    )
    .map((key) => ({
      key,
      regex: new RegExp(
        `^${key
          .split(/\{\d+\}/)
          .map(escape)
          .join("(.*?)")}$`,
        "s",
      ),
    }));
  loadError = "";
  changed();
}
try {
  const saved = localStorage.getItem("localizations");
  if (saved) installTranslations(JSON.parse(saved));
} catch {
  /* Discard an invalid cache, keeping readable source labels. */
}

/** One complete resource request per page session; language switching is local. */
export function loadTranslations(): Promise<void> {
  if (request) return request;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  request = Promise.resolve().then(async () => {
    try {
      const response = await globalThis.fetch("/api/v1/localizations/get", {
        method: "POST",
        credentials: "omit",
        headers: { "Content-Type": "application/json" },
        body: "{}",
        signal: controller.signal,
      });
      if (!response.ok) throw new Error("无法加载界面语言，请重试。");
      const body = await response.json();
      const next = validateCatalog(body.data);
      installTranslations(next);
      try {
        localStorage.setItem("localizations", JSON.stringify(next));
      } catch {
        /* Usable in memory even if the cache is full. */
      }
    } catch (error) {
      request = null;
      loadError = "无法加载界面语言，请重试。";
      changed();
      throw error;
    } finally {
      clearTimeout(timeout);
    }
  });
  return request;
}
if (typeof window !== "undefined")
  window.addEventListener("storage", (event) => {
    if (event.key === "language" || event.key === null) {
      const selected = savedLanguage();
      language = availableLanguages().some((entry) => entry.code === selected)
        ? selected
        : (catalog?.default_language ?? "zh");
      changed();
    }
  });
export function useLanguage(): string {
  useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    snapshot,
    () => "0:zh",
  );
  return language;
}
export function formatLocale() {
  return (
    availableLanguages().find((entry) => entry.code === language)?.locale ??
    language
  );
}
/** Explicit interface strings only, never business-record names. */
export function tr(source: string, args: unknown[] = []): string {
  const template = catalog?.translations[language]?.[source] ?? source;
  return template.replace(/\{(\d+)\}/g, (match, index: string) =>
    Number(index) < args.length ? String(args[Number(index)] ?? "") : match,
  );
}
/** Known errors/warnings translate at render time; unknown model notes stay intact. */
export function message(source: string): string {
  if (catalog?.translations[language]?.[source]) return tr(source);
  if (source.startsWith("Error: ")) return `Error: ${message(source.slice(7))}`;
  for (const { key, regex } of patterns) {
    const match = regex.exec(source);
    if (match) return tr(key, match.slice(1));
  }
  return source.includes("\n")
    ? source.split("\n").map(message).join("\n")
    : source;
}
