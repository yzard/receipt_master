import { tr, message, useLanguage } from "./i18n";
import React, { useEffect, useId, useState } from "react";
import { api, Row } from "./api";
export function catalogNameKey(value: string): string {
  return value
    .normalize("NFKC")
    .trim()
    .replace(/\s+/gu, " ")
    .replace(/[A-Z]/g, (letter) => letter.toLowerCase());
}
export function CatalogSearchInput({
  label,
  value,
  onChange,
  component,
  labelField = "name",
  disabled = false,
  required = false,
  onBlur,
  onSelect,
  rejectExistingName = false,
  currentId,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  component: "product_names" | "categories";
  labelField?: string;
  disabled?: boolean;
  required?: boolean;
  onBlur?: () => void;
  onSelect?: (row: Row) => void;
  rejectExistingName?: boolean;
  currentId?: string;
}) {
  useLanguage();

  const id = useId();
  const [focused, setFocused] = useState(false);
  const [rows, setRows] = useState<Row[]>([]);
  const [highlight, setHighlight] = useState(-1);
  const [error, setError] = useState("");
  const existing = rows.find(
    (row) =>
      (row.exact_match || catalogNameKey(row.name) === catalogNameKey(value)) &&
      (row.product_name_id || row.category_id) !== currentId,
  );
  const duplicate = Boolean(existing && rejectExistingName);
  const notice = duplicate
    ? tr("商品种类名称已存在，请使用其他名称")
    : existing
      ? tr("已有同名记录，将使用已有名称，不会重复添加")
      : "";
  useEffect(() => {
    let active = true;
    setRows([]);
    setHighlight(-1);
    if (!focused || disabled) return;
    const timer = setTimeout(() => {
      void api
        .op(component, "suggest", { query: value })
        .then((result: Row[]) => {
          if (active) {
            setRows(result);
            setError("");
          }
        })
        .catch(() => {
          if (active) setError("搜索失败，可继续输入或重试");
        });
    }, 180);
    return () => {
      active = false;
      clearTimeout(timer);
    };
  }, [value, component, focused, disabled]);
  function choose(row: Row) {
    onChange(row[labelField]);
    setFocused(false);
    onSelect?.(row);
  }
  return (
    <div className="catalog-search field">
      <label htmlFor={id}>{label}</label>
      <input
        id={id}
        role="combobox"
        autoComplete="off"
        value={value}
        aria-autocomplete="list"
        aria-expanded={focused && rows.length > 0}
        aria-controls={`${id}-options`}
        aria-activedescendant={
          highlight >= 0 ? `${id}-option-${highlight}` : undefined
        }
        disabled={disabled}
        required={required}
        aria-invalid={duplicate}
        aria-describedby={notice ? `${id}-notice` : undefined}
        ref={(input) => input?.setCustomValidity(duplicate ? notice : "")}
        onFocus={() => setFocused(true)}
        onChange={(e) => {
          setFocused(true);
          onChange(e.target.value);
        }}
        onBlur={() => {
          setFocused(false);
          onBlur?.();
        }}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            setFocused(false);
            e.preventDefault();
          }
          if (
            focused &&
            rows.length &&
            ["ArrowDown", "ArrowUp"].includes(e.key)
          ) {
            e.preventDefault();
            setHighlight(
              (old) =>
                (old + (e.key === "ArrowDown" ? 1 : -1) + rows.length) %
                rows.length,
            );
          }
          if (
            e.key === "Enter" &&
            focused &&
            highlight >= 0 &&
            rows[highlight]
          ) {
            e.preventDefault();
            choose(rows[highlight]);
          }
        }}
      />
      {focused && rows.length > 0 && (
        <div id={`${id}-options`} role="listbox" className="catalog-options">
          {rows.map((row, index) => (
            <button
              type="button"
              role="option"
              id={`${id}-option-${index}`}
              key={row.product_name_id || row.category_id}
              aria-selected={highlight === index}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => choose(row)}
            >
              {row[labelField]}
            </button>
          ))}
        </div>
      )}
      {focused && error && <small role="status">{message(error)}</small>}
      {notice && (
        <small id={`${id}-notice`} role={duplicate ? "alert" : "status"}>
          {message(notice)}
        </small>
      )}
    </div>
  );
}
