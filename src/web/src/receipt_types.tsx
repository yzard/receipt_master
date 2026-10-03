import React, { useEffect, useState } from "react";
import { api, type Row } from "./api";

export function ReceiptTypesManager() {
  const [types, setTypes] = useState<Row[]>([]),
    [merchants, setMerchants] = useState<Row[]>([]);
  const [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const [edit, setEdit] = useState<Row | null>(null),
    [name, setName] = useState("");
  async function load() {
    const [t, m] = await Promise.all([
      api.op("receipt_types", "list"),
      api.op("merchants", "list"),
    ]);
    setTypes(t);
    setMerchants(m);
  }
  useEffect(() => {
    load().catch((e) => setError(String(e)));
  }, []);
  async function action(f: () => Promise<unknown>) {
    setBusy(true);
    setError("");
    try {
      await f();
      await load();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <section aria-label="店铺类别管理">
      <p className="muted">
        店铺类别与商品种类独立；店铺类别用来填充新识别收据的默认值，修改店铺不会改变历史消费。
      </p>
      {error && (
        <p className="notice" role="alert">
          {error}
        </p>
      )}
      <div className="tags">
        {types.map((t) => (
          <span className="tag" key={t.receipt_type_id}>
            <button
              disabled={busy || !!t.system_key}
              onClick={() => {
                setEdit(t);
                setName(t.name);
              }}
            >
              {t.name}
            </button>
            {!t.system_key && (
              <button
                aria-label={`删除店铺类别 ${t.name}`}
                disabled={busy}
                onClick={() => {
                  if (
                    confirm(
                      "删除此类别？保留所有收据，关联消费和店铺变为未分类。",
                    )
                  )
                    void action(() =>
                      api.op("receipt_types", "delete", {
                        id: t.receipt_type_id,
                        expected_version: api.version,
                      }),
                    );
                }}
              >
                ×
              </button>
            )}
          </span>
        ))}
      </div>
      <button
        disabled={busy}
        onClick={() => {
          setEdit({ receipt_type_id: null });
          setName("");
        }}
      >
        添加店铺类别
      </button>
      {edit && (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void action(async () => {
              await api.op("receipt_types", "save", {
                id: edit.receipt_type_id,
                name,
                expected_version: api.version,
              });
              setEdit(null);
            });
          }}
        >
          <label>
            店铺类别名称
            <input
              aria-label="店铺类别名称"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              autoFocus
            />
          </label>
          <button type="button" onClick={() => setEdit(null)}>
            取消
          </button>
          <button disabled={busy} type="submit">
            保存类别
          </button>
        </form>
      )}
      <h2>店铺类别设置</h2>
      <div className="mapping-list">
        {merchants.map((m) => (
          <label className="mapping" key={m.merchant_id}>
            <span>{m.name}</span>
            <select
              aria-label={`${m.name}的店铺类别`}
              disabled={busy}
              value={m.receipt_type_id}
              onChange={(e) =>
                void action(() =>
                  api.op("merchants", "classify", {
                    id: m.merchant_id,
                    receipt_type_id: e.target.value,
                    expected_version: api.version,
                  }),
                )
              }
            >
              {types.map((t) => (
                <option key={t.receipt_type_id} value={t.receipt_type_id}>
                  {t.name}
                </option>
              ))}
            </select>
          </label>
        ))}
      </div>
    </section>
  );
}
