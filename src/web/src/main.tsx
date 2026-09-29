import React, { useState, useEffect, useRef, useId, FormEvent } from "react";
import {
  api,
  Row,
  User,
  money,
  date,
  zone,
  currencies,
  emptyReceipt,
  emptyLine,
  receiptList,
  download,
  decode64,
  encode64,
} from "./api";
import { enqueue, pending, retry, Submission } from "./uploads";
import "./style.css";
const names: Record<string, string> = {
  receipts: "收据",
  reports: "报表",
  catalog: "商品管理",
  stores: "商店名称",
  settings: "设置",
  users: "用户管理",
};
const kinds: Record<string, string> = {
  product: "商品",
  other_adjustment: "其他调整",
  item_discount: "商品优惠",
  order_discount: "整单优惠",
  tax: "税费",
  tip: "小费",
  deposit: "押金",
};
const paths: Record<string, string> = {
  menu: "M4 6h16M4 12h16M4 18h16",
  camera: "M4 7h4l2-3h4l2 3h4v13H4z M16 13a4 4 0 1 1-8 0 4 4 0 0 1 8 0",
  upload: "M12 16V3m-5 5 5-5 5 5M4 15v6h16v-6",
  add: "M12 4v16M4 12h16",
  close: "m5 5 14 14M19 5 5 19",
  refresh: "M20 7V3l-4 4a8 8 0 1 0 3 10M20 3v5h-5",
  trash: "M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7",
  receipt: "M5 3h14v18l-3-2-4 2-4-2-3 2zM8 7h8M8 11h8M8 15h5",
  reports: "M3 21h18M6 17v-5M12 17V7M18 17V3",
  catalog: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z",
  settings:
    "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M9 3h6l1 4 4 1v7l-4 1-1 5H9l-1-5-4-1V8l4-1z",
  stores: "M3 10h18l-3-7H6zM5 10v11h14V10M9 21v-7h6v7",
  users:
    "M8 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8M1 21v-3a7 7 0 0 1 14 0v3M17 4a4 4 0 0 1 0 8M17 15a6 6 0 0 1 6 6",
  back: "m14 5-7 7 7 7",
  rotate: "M20 6V2l-4 4a8 8 0 1 0 4 9M20 2v5h-5",
  check: "m4 12 5 5L20 6",
  logout: "M9 3H3v18h6M10 12h11m-4-4 4 4-4 4",
  download: "M12 3v13m-5-5 5 5 5-5M4 16v5h16v-5",
};
function Icon({ name }: { name: string }) {
  return (
    <svg
      width="22"
      height="22"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={paths[name] || paths.receipt} />
    </svg>
  );
}
function IconButton({
  icon,
  label,
  onClick,
  disabled = false,
}: {
  icon: string;
  label: string;
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <button
      className="icon-button"
      title={label}
      aria-label={label}
      onClick={onClick}
      disabled={disabled}
    >
      <Icon name={icon} />
    </button>
  );
}
function notify(message: string) {
  window.dispatchEvent(new CustomEvent("notice", { detail: message }));
}
async function action(f: () => Promise<any>) {
  try {
    await f();
  } catch (e) {
    notify(e instanceof Error ? e.message : String(e));
  }
}
export function AndroidDownloadLink({ className }: { className: string }) {
  return (
    <a
      className={className}
      href="/receipt_master.apk"
      download="receipt_master.apk"
      title="安装后使用同一用户名和密码登录"
      onClick={(event) => {
        event.preventDefault();
        void action(async () => {
          await api.ready();
          const link = document.createElement("a");
          link.href = "/receipt_master.apk";
          link.download = "receipt_master.apk";
          document.body.append(link);
          link.click();
          link.remove();
        });
      }}
    >
      <Icon name="download" />
      下载 Android APK
    </a>
  );
}
function Field({
  label,
  value,
  onChange,
  type = "text",
  required = false,
  ...rest
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  type?: string;
  required?: boolean;
  [key: string]: any;
}) {
  return (
    <label className="field">
      <span>{label}</span>
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        type={type}
        required={required}
        {...rest}
      />
    </label>
  );
}
function Select({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  options: [string, string][];
}) {
  return (
    <label className="field">
      <span>{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {options.map(([key, text]) => (
          <option key={key} value={key}>
            {text}
          </option>
        ))}
      </select>
    </label>
  );
}
function Modal({
  title,
  onClose,
  children,
  wide = false,
}: {
  title: string;
  onClose: () => void;
  children: React.ReactNode;
  wide?: boolean;
}) {
  const titleId = useId();
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    ref.current?.showModal();
    return () => ref.current?.close();
  }, []);
  return (
    <dialog
      ref={ref}
      aria-labelledby={titleId}
      className={wide ? "modal wide" : "modal"}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <header>
        <h2 id={titleId}>{title}</h2>
        <IconButton icon="close" label="关闭" onClick={onClose} />
      </header>
      {children}
    </dialog>
  );
}
function Heading({
  title,
  subtitle,
  action: extra,
}: {
  title: string;
  subtitle?: string;
  action?: React.ReactNode;
}) {
  return (
    <header className="page-heading">
      <div>
        <p className="eyebrow">RECEIPT MASTER</p>
        <h1>{title}</h1>
        {subtitle && <p className="muted">{subtitle}</p>}
      </div>
      {extra}
    </header>
  );
}
function StateView({
  error,
  busy,
  empty,
  onRetry,
}: {
  error?: string;
  busy?: boolean;
  empty?: string;
  onRetry?: () => void;
}) {
  return error ? (
    <div className="notice error" role="alert">
      {error} <button onClick={onRetry}>重试</button>
    </div>
  ) : busy ? (
    <div className="loading" role="status">
      正在加载…
    </div>
  ) : empty ? (
    <div className="empty">
      <Icon name="receipt" />
      <h3>{empty}</h3>
      <p>记录一张收据，让每次消费都有迹可循。</p>
    </div>
  ) : null;
}
function useLoad(loader: () => Promise<any>, deps: any[], interval = 0) {
  const [data, setData] = useState<any>(null),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [revision, setRevision] = useState(0);
  const reload = () => setRevision((n) => n + 1);
  useEffect(() => {
    let current = true;
    async function load() {
      try {
        setBusy(true);
        const value = await loader();
        if (current) {
          setData(value);
          setError("");
        }
      } catch (e) {
        if (current) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (current) setBusy(false);
      }
    }
    void load();
    const timer = interval ? setInterval(load, interval) : null;
    return () => {
      current = false;
      if (timer) clearInterval(timer);
    };
  }, [...deps, revision]);
  return { data, error, busy, reload, setData };
}
export function SignIn({
  change = false,
  onDone,
}: {
  change?: boolean;
  onDone?: () => void;
}) {
  const [name, setName] = useState(""),
    [password, setPassword] = useState(""),
    [newPassword, setNew] = useState(""),
    [repeat, setRepeat] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const values = new FormData(e.currentTarget);
    const username = String(values.get("username") ?? "");
    const currentPassword = String(values.get("password") ?? "");
    const nextPassword = String(values.get("new-password") ?? "");
    const confirmation = String(values.get("confirm-password") ?? "");
    setName(username);
    setPassword(currentPassword);
    setNew(nextPassword);
    setRepeat(confirmation);
    if (change && nextPassword !== confirmation) {
      setError("两次新密码不一致");
      return;
    }
    setBusy(true);
    setError("");
    try {
      if (change) await api.change(currentPassword, nextPassword);
      else await api.login(username, currentPassword);
      onDone?.();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <main className="auth-page">
      <section className="auth-card">
        <div className="brand-mark">
          <Icon name="receipt" />
        </div>
        <p className="eyebrow">RECEIPT MASTER</p>
        <h1>{change ? "设置你的新密码" : "生活账目，一目了然。"}</h1>
        <p className="muted">
          {change
            ? "首次登录或密码被重置后，修改密码才能继续。"
            : "登录，继续整理收据、商品与消费趋势。"}
        </p>
        <form
          id={change ? "change-password-form" : "login-form"}
          name={change ? "change-password" : "login"}
          action={change ? "/api/auth/change-password" : "/api/auth/login"}
          method="post"
          autoComplete="on"
          onSubmit={submit}
        >
          <Field
            label="用户名"
            id={change ? "change-username" : "login-username"}
            name="username"
            value={change ? (api.user?.username ?? name) : name}
            onChange={setName}
            readOnly={change}
            required
            autoComplete="username"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            autoFocus={!change}
          />
          <Field
            label={change ? "当前密码" : "密码"}
            id={change ? "current-password" : "login-password"}
            name="password"
            value={password}
            onChange={setPassword}
            type="password"
            required
            autoComplete="current-password"
          />
          {change && (
            <>
              <Field
                label="新密码 · 至少 12 个字符"
                id="new-password"
                name="new-password"
                value={newPassword}
                onChange={setNew}
                type="password"
                required
                minLength={12}
                autoComplete="new-password"
              />
              <Field
                label="再次输入新密码"
                id="confirm-password"
                name="confirm-password"
                value={repeat}
                onChange={setRepeat}
                type="password"
                required
                minLength={12}
                autoComplete="new-password"
              />
            </>
          )}
          {error && (
            <p className="notice error" role="alert">
              {error}
            </p>
          )}
          <button className="primary" disabled={busy}>
            {busy ? "正在处理…" : change ? "修改密码" : "登录"}
          </button>
        </form>
        {change && (
          <button
            className="text-button"
            onClick={() => void action(() => api.logout())}
          >
            退出登录
          </button>
        )}
        <p className="auth-footer">收据、照片与分析，仅属于你的账户。</p>
      </section>
    </main>
  );
}
function Camera({ onClose }: { onClose: () => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const [photos, setPhotos] = useState<Blob[]>([]),
    [urls, setUrls] = useState<string[]>([]),
    [selected, setSelected] = useState(0),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  useEffect(() => {
    let stream: MediaStream | undefined;
    let closed = false;
    navigator.mediaDevices
      ?.getUserMedia({
        video: {
          facingMode: "environment",
          width: { ideal: 4080 },
          height: { ideal: 3060 },
        },
        audio: false,
      })
      .then((s) => {
        if (closed) {
          s.getTracks().forEach((t) => t.stop());
          return;
        }
        stream = s;
        if (video.current) video.current.srcObject = s;
      })
      .catch((e) =>
        setError(`无法打开相机：${e.message}。请检查浏览器权限并使用 HTTPS。`),
      );
    if (!navigator.mediaDevices)
      setError("此浏览器环境没有相机权限，请使用 HTTPS 或上传照片。");
    return () => {
      closed = true;
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, []);
  useEffect(() => {
    const next = photos.map((p) => URL.createObjectURL(p));
    setUrls(next);
    return () => next.forEach(URL.revokeObjectURL);
  }, [photos]);
  function shoot(replace = false) {
    const v = video.current;
    if (!v?.videoWidth) return;
    const c = document.createElement("canvas");
    c.width = v.videoWidth;
    c.height = v.videoHeight;
    c.getContext("2d")!.drawImage(v, 0, 0);
    c.toBlob(
      (blob) => {
        if (blob) {
          setPhotos((p) =>
            replace
              ? p.map((a, i) => (i === selected ? blob : a))
              : [...p, blob],
          );
          if (!replace) setSelected(photos.length);
        }
      },
      "image/jpeg",
      0.96,
    );
  }
  async function done() {
    setBusy(true);
    try {
      await enqueue(photos, true);
      onClose();
    } catch (e) {
      setError(String(e));
      setBusy(false);
    }
  }
  return (
    <Modal title="拍摄收据" onClose={onClose} wide>
      <video ref={video} autoPlay playsInline muted className="viewfinder" />
      {error && <p className="notice error">{error}</p>}
      <div className="photo-strip">
        {urls.map((u, i) => (
          <div key={u} className={selected === i ? "selected" : ""}>
            <button className="photo-select" onClick={() => setSelected(i)}>
              <img src={u} alt={`第 ${i + 1} 张`} />
            </button>
            <IconButton
              icon="close"
              label={`删除第 ${i + 1} 张照片`}
              onClick={() => {
                setPhotos((p) => p.filter((_, j) => j !== i));
                setSelected(0);
              }}
            />
          </div>
        ))}
      </div>
      <footer>
        <button onClick={() => shoot(true)} disabled={!photos.length || busy}>
          重拍
        </button>
        <button
          className="primary"
          onClick={() => shoot()}
          disabled={busy || !!error}
        >
          拍摄
        </button>
        <button onClick={() => void done()} disabled={!photos.length || busy}>
          完成 · {photos.length} 张
        </button>
      </footer>
    </Modal>
  );
}
export function Receipts({
  open,
  productId = null,
  title = "收据",
}: {
  open: (id: string) => void;
  productId?: string | null;
  title?: string;
}) {
  const [sort, setSort] = useState("created_at"),
    [direction, setDirection] = useState("desc");
  const list = useLoad(
    () => receiptList({ sort_by: sort, direction, product_name_id: productId }),
    [sort, direction, productId],
    5000,
  );
  const [submissions, setSubmissions] = useState<Submission[]>([]);
  useEffect(() => {
    const load = () =>
      void pending()
        .then(setSubmissions)
        .catch(() => {});
    load();
    window.addEventListener("submissions", load);
    return () => window.removeEventListener("submissions", load);
  }, []);
  function order(field: string) {
    if (field === sort) setDirection((d) => (d === "desc" ? "asc" : "desc"));
    else {
      setSort(field);
      setDirection(field === "store" ? "asc" : "desc");
    }
  }
  async function remove(r: Row) {
    if (confirm("永久删除这张收据及其照片？")) {
      await api.op("receipts", "purge", {
        id: r.receipt_id,
        expected_version: r.version,
      });
      list.reload();
    }
  }
  return (
    <>
      <Heading
        title={title}
        subtitle="每张票据，都是生活的一个细节。"
        action={
          <IconButton icon="refresh" label="刷新收据" onClick={list.reload} />
        }
      />
      {submissions.length > 0 && (
        <div className="notice">
          {submissions.length} 张收据正在上传或等待重试。
          <button onClick={() => void action(retry)}>重试上传</button>
          {submissions
            .filter((s) => s.error)
            .map((s) => (
              <p key={s.id}>{s.error}</p>
            ))}
        </div>
      )}
      <StateView
        error={list.error}
        busy={!list.data && list.busy}
        onRetry={list.reload}
      />
      {list.data?.length === 0 && <StateView empty="还没有收据" />}
      {!!list.data?.length && (
        <div className="table-scroll">
          <table className="receipt-table">
            <thead>
              <tr>
                {[
                  ["store", "店名"],
                  ["created_at", "录入时间"],
                  ["receipt_time", "收据时间"],
                  ["total", "总金额"],
                ].map(([key, label]) => (
                  <th
                    key={key}
                    aria-sort={
                      sort === key
                        ? direction === "asc"
                          ? "ascending"
                          : "descending"
                        : "none"
                    }
                  >
                    <button onClick={() => order(key)}>
                      {label}{" "}
                      {sort === key ? (direction === "asc" ? "↑" : "↓") : ""}
                    </button>
                  </th>
                ))}
                <th>
                  <span className="sr-only">操作</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {list.data.map((r: Row) => (
                <tr
                  key={r.receipt_id}
                  className={
                    r.recognition_status === "failed"
                      ? "failed"
                      : r.status === "draft"
                        ? "draft"
                        : ""
                  }
                >
                  <td>
                    <button
                      className="row-link"
                      onClick={() => open(r.receipt_id)}
                    >
                      {r.raw_store || "未知商店"}
                      {["queued", "running"].includes(r.recognition_status) && (
                        <small>识别中…</small>
                      )}
                    </button>
                  </td>
                  <td>{date(r.created_at_utc_ms)}</td>
                  <td>{date(r.occurred_at_utc_ms)}</td>
                  <td className="numeric">
                    {money(r.total_minor, r.currency_code)}
                  </td>
                  <td>
                    <IconButton
                      icon="trash"
                      label="删除收据"
                      onClick={() => void action(() => remove(r))}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
export function LineEditor({
  line,
  lines,
  currency,
  categories,
  onSave,
  onClose,
}: {
  line: Row;
  lines: Row[];
  currency: string;
  categories: Row[];
  onSave: (line: Row) => void;
  onClose: () => void;
}) {
  const [value, setValue] = useState<Row>(structuredClone(line)),
    [fields, setFields] = useState<Row>(structuredClone(line.display)),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const suggestions = useLoad(() => api.op("product_names", "list"), []);
  function set(key: string, v: any) {
    setValue((r: Row) => ({ ...r, [key]: v }));
  }
  async function save(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      const prepared = await api.op("receipts", "prepare_line", {
        line: value,
        currency,
        fields,
      });
      onSave(prepared);
      onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal title="编辑商品" onClose={onClose}>
      <form onSubmit={save}>
        <Field
          label="票面名称"
          value={value.rawName}
          onChange={(v) => set("rawName", v)}
          required
        />
        <Field
          label="商品名称"
          value={value.productNameEdit ?? value.display?.productName ?? ""}
          onChange={(v) => set("productNameEdit", v)}
          list="product-names"
        />
        <datalist id="product-names">
          {suggestions.data?.map((n: Row) => (
            <option key={n.product_name_id} value={n.name} />
          ))}
        </datalist>
        <div className="form-grid">
          <Select
            label="类型"
            value={value.kind}
            onChange={(v) => {
              const system = categories.find((c: Row) => c.system_key === v);
              setValue((r: Row) => ({
                ...r,
                kind: v,
                discountTarget: v === "item_discount" ? r.discountTarget : null,
                categoryId:
                  system?.category_id || "00000000-0000-4000-8000-000000000001",
              }));
            }}
            options={Object.entries(kinds)}
          />
          <Select
            label="商品分类"
            value={value.categoryId}
            onChange={(v) => set("categoryId", v)}
            options={categories.map((c) => [c.category_id, c.path])}
          />
          {value.kind === "item_discount" && (
            <Select
              label="折扣对应商品"
              value={value.discountTarget || ""}
              onChange={(v) => set("discountTarget", v || null)}
              options={[
                ["", "请选择商品"],
                ...lines
                  .filter((l: Row) => l.kind === "product" && l.id !== value.id)
                  .map((l: Row): [string, string] => [
                    l.id,
                    l.productNameEdit || l.display?.productName || l.rawName,
                  ]),
              ]}
            />
          )}
          <Field
            label="税码"
            value={value.taxCode ?? ""}
            maxLength={1}
            onChange={(v) => set("taxCode", v || null)}
          />
          <Field
            label="SKU"
            value={value.sku ?? ""}
            onChange={(v) => set("sku", v || null)}
          />
          {[
            ["amountText", `金额 (${currency})`],
            ["weightText", `重量 (${fields.weightUnit})`],
            ["quantityText", "数量"],
            ["quantityUnit", "计价单位"],
            ["priceText", "单价"],
          ].map(([key, label]) => (
            <Field
              key={key}
              label={label}
              value={fields[key] ?? ""}
              onChange={(v) => setFields((f: Row) => ({ ...f, [key]: v }))}
              inputMode={key === "quantityUnit" ? "text" : "decimal"}
            />
          ))}
        </div>
        <label className="check">
          <input
            type="checkbox"
            checked={value.isWeighed}
            onChange={(e) => set("isWeighed", e.target.checked)}
          />
          称重商品
        </label>
        {value.warnings?.length > 0 && (
          <div className="notice">
            {value.warnings.map((w: string) => (
              <p key={w}>{w}</p>
            ))}
            <button type="button" onClick={() => set("warnings", [])}>
              已核对，清除提示
            </button>
          </div>
        )}
        {error && <p className="notice error">{error}</p>}
        <footer>
          <button type="button" onClick={onClose}>
            取消
          </button>
          <button className="primary" disabled={busy}>
            应用修改
          </button>
        </footer>
      </form>
    </Modal>
  );
}
export function Editor({ id, onBack }: { id: string; onBack: () => void }) {
  const loaded = useLoad(
    async () =>
      Promise.all([
        api.op("receipts", "get", { id }),
        api.op("images", "list", { receipt_id: id }),
        api.op("categories", "list"),
      ]),
    [id],
  );
  const [r, setR] = useState<Row | null>(null),
    [total, setTotal] = useState(""),
    [dirty, setDirty] = useState(false),
    [line, setLine] = useState<Row | null>(null),
    [selected, setSelected] = useState<string[]>([]),
    [photo, setPhoto] = useState<string | null>(null),
    [busy, setBusy] = useState(false),
    [storeEdit, setStoreEdit] = useState(false),
    [timeChoices, setTimeChoices] = useState<{
      text: string;
      times: number[];
    } | null>(null),
    [error, setError] = useState("");
  useEffect(() => {
    if (loaded.data) {
      setR(loaded.data[0]);
      setTotal(
        loaded.data[0].totalMinor == null
          ? ""
          : moneyDecimal(loaded.data[0].totalMinor, loaded.data[0].currency),
      );
      setDirty(false);
    }
  }, [loaded.data]);
  useEffect(() => {
    if (!r || !dirty) return;
    let cancelled = false;
    const timer = setTimeout(() => {
      void api
        .op("receipts", "edit", {
          receipt: r,
          action: "preview",
          total_text: total,
        })
        .then((value) => {
          if (!cancelled)
            setR((current) =>
              current ? { ...current, summary: value.summary } : current,
            );
        })
        .catch(() => {});
    }, 300);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [r?.lines, r?.currency, total, dirty]);
  function update(key: string, value: any) {
    setR((r: Row | null) => ({ ...r!, [key]: value }));
    setDirty(true);
  }
  async function edit(operation: string, extra: Row = {}) {
    const result = await api.op("receipts", "edit", {
      receipt: r,
      action: operation,
      total_text: total,
      ...extra,
    });
    setR(result);
    setTotal(
      result.totalMinor == null
        ? ""
        : moneyDecimal(result.totalMinor, result.currency),
    );
    setDirty(true);
    return result;
  }
  async function save(publish: boolean) {
    const preview = await api.op("receipts", "edit", {
      receipt: r,
      action: "preview",
      total_text: total,
    });
    if (publish) {
      const dup = await api.op("receipts", "check_duplicates", {
        receipt: preview,
      });
      if (
        dup.length &&
        !confirm(`发现 ${dup.length} 张可能重复的收据，仍确认保存？`)
      )
        return;
    }
    const result = await api.op(
      "receipts",
      publish || r?.posted ? "confirm" : "save",
      {
        receipt: preview,
      },
    );
    setR(result);
    setDirty(false);
    return result;
  }
  async function doAction(f: () => Promise<any>) {
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      await f();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }
  function back() {
    if (dirty && !confirm("放弃尚未保存的修改？")) return;
    onBack();
  }
  async function imageAction(operation: string, input: Row) {
    const current = dirty ? await save(false) : r;
    await api.op("images", operation, {
      receipt_id: id,
      expected_version: current.revision,
      ...input,
    });
    loaded.reload();
  }
  async function recognize() {
    if (
      !confirm(
        r?.posted
          ? "重新识别会将已确认收据放回草稿。继续？"
          : "重新识别这张收据？",
      )
    )
      return;
    const current = dirty ? await save(false) : r;
    await api.op("recognition", "start", {
      receipt_id: id,
      expected_version: current.revision,
      zone,
    });
    notify("已加入识别队列，可继续处理其他收据。");
    onBack();
  }
  if (!r)
    return (
      <>
        <IconButton icon="back" label="返回" onClick={back} />
        <StateView
          busy={loaded.busy}
          error={loaded.error}
          onRetry={loaded.reload}
        />
      </>
    );
  return (
    <>
      <div className="editor-heading">
        <IconButton icon="back" label="返回收据" onClick={back} />
        <div>
          <h1>{r.store || "收据草稿"}</h1>
          <small>{id}</small>
        </div>
        <span className="spacer" />
        <IconButton
          icon="refresh"
          label="重新识别"
          disabled={busy || !loaded.data?.[1].length}
          onClick={() => void doAction(recognize)}
        />
        <IconButton
          icon="trash"
          label="删除收据"
          disabled={busy}
          onClick={() =>
            void doAction(async () => {
              if (confirm("永久删除这张收据？")) {
                await api.op("receipts", "purge", {
                  id,
                  expected_version: r.revision,
                });
                onBack();
              }
            })
          }
        />
      </div>
      {error && (
        <p className="notice error" role="alert">
          {error}
        </p>
      )}
      <div className="editor-layout">
        <aside className="receipt-photos">
          {loaded.data?.[1].length === 0 && (
            <p className="muted">手动录入的收据没有照片。</p>
          )}
          {loaded.data?.[1].map((img: Row, i: number) => (
            <figure key={img.image_id}>
              <button
                className="photo-select"
                onClick={() => setPhoto(`/api/v1/media/${img.media_id}`)}
              >
                <img
                  src={`/api/v1/media/${img.media_id}`}
                  alt={`收据第 ${i + 1} 张`}
                />
              </button>
              <figcaption>
                第 {i + 1} 张
                <div>
                  <IconButton
                    icon="rotate"
                    label="旋转照片"
                    disabled={busy}
                    onClick={() =>
                      void doAction(() =>
                        imageAction("rotate", { id: img.image_id }),
                      )
                    }
                  />
                  {i > 0 && (
                    <button
                      title="向前移动照片"
                      disabled={busy}
                      onClick={() =>
                        void doAction(() => {
                          const ids = loaded.data[1].map(
                            (p: Row) => p.image_id,
                          );
                          [ids[i - 1], ids[i]] = [ids[i], ids[i - 1]];
                          return imageAction("reorder", { ids });
                        })
                      }
                    >
                      ←
                    </button>
                  )}
                  <IconButton
                    icon="trash"
                    label="删除照片"
                    disabled={busy}
                    onClick={() =>
                      void doAction(async () => {
                        if (confirm("删除这张照片？"))
                          await imageAction("remove", { id: img.image_id });
                      })
                    }
                  />
                </div>
              </figcaption>
            </figure>
          ))}
        </aside>
        <section>
          <div className="form-grid">
            {[
              ["store", "商店名称"],
              ["branch", "分店"],
              ["address", "地址"],
              ["country", "国家代码"],
            ].map(([key, label]) => (
              <Field
                key={key}
                label={label}
                value={r[key] || ""}
                onChange={(v) =>
                  update(key, key === "country" ? v.toUpperCase() : v)
                }
              />
            ))}
            <Select
              label="币种"
              value={r.currency}
              options={currencies.map((c) => [c, c])}
              onChange={(v) =>
                void doAction(() => edit("currency", { currency: v }))
              }
            />
            <Field
              label="票面总金额"
              value={total}
              onChange={(v) => {
                setTotal(v);
                setDirty(true);
              }}
              inputMode="decimal"
            />
            <Field
              label={`收据时间 · ${zone}`}
              type="datetime-local"
              value={localInput(r.occurredAt)}
              onChange={(v) =>
                void doAction(async () => {
                  const times = await api.op("receipts", "time_candidates", {
                    text: v.replace("T", " "),
                    zone,
                  });
                  if (!times.length) throw new Error("此时间在当前时区不存在");
                  if (times.length > 1) {
                    setTimeChoices({ text: v, times });
                    return;
                  }
                  update("occurredAt", times[0]);
                  update("timeSource", "user_entered");
                  update("rawTime", v.replace("T", " "));
                })
              }
            />
            <Select
              label="时间来源"
              value={r.timeSource}
              onChange={(v) => update("timeSource", v)}
              options={Object.entries({
                recognized: "票面识别",
                user_entered: "手动确认",
                estimated_clock: "估计 · 录入时间",
                estimated_instant: "用户指定估计时间",
              })}
            />
          </div>
          <button onClick={() => setStoreEdit(true)}>编辑商店 Logo 名称</button>
          <div className="section-heading">
            <h2>
              商品明细 <small>{r.lines.length}</small>
            </h2>
            <button
              onClick={() =>
                void doAction(async () => {
                  const l = await api.op("receipts", "display_line", {
                    line: emptyLine(),
                    currency: r.currency,
                  });
                  setLine(l);
                })
              }
            >
              <Icon name="add" />
              添加
            </button>
          </div>
          {r.lines.length === 0 && (
            <p className="muted">还没有商品明细。识别完成后会显示在这里。</p>
          )}
          {r.lines.map((l: Row) => (
            <div
              key={l.id}
              className={`line ${l.warnings.length ? "warning" : ""}`}
            >
              <input
                type="checkbox"
                checked={selected.includes(l.id)}
                aria-label={`选择 ${l.rawName}`}
                onChange={(e) =>
                  setSelected((s) =>
                    e.target.checked
                      ? [...s, l.id]
                      : s.filter((id) => id !== l.id),
                  )
                }
              />
              <button className="line-main" onClick={() => setLine(l)}>
                <strong>
                  {l.display?.productName || l.rawName || "未命名商品"}
                </strong>
                {l.display?.productName && <small>{l.rawName}</small>}
                <div className="line-meta">
                  {kinds[l.kind]} {l.taxCode && `· 税码 ${l.taxCode}`}{" "}
                  {l.sku && `· SKU ${l.sku}`}{" "}
                  {l.display?.weightLabel && `· ${l.display.weightLabel}`}
                </div>
                {l.warnings.map((w: string) => (
                  <p className="warning-text" key={w}>
                    {w}
                  </p>
                ))}
              </button>
              <span className="numeric">
                {money(l.amountMinor, r.currency)}
              </span>
              <IconButton
                icon="trash"
                label="删除商品"
                onClick={() => {
                  if (confirm("删除这一项？"))
                    update(
                      "lines",
                      r.lines.filter(
                        (a: Row) => a.id !== l.id && a.discountTarget !== l.id,
                      ),
                    );
                }}
              />
            </div>
          ))}
          <div className="inline-actions">
            <button
              disabled={selected.length !== 1}
              onClick={() => {
                const amount = prompt("拆分出的金额");
                if (amount !== null)
                  void doAction(() =>
                    edit("split", { selected, amount_text: amount }),
                  );
              }}
            >
              拆分
            </button>
            <button
              disabled={selected.length < 2}
              onClick={() => void doAction(() => edit("merge", { selected }))}
            >
              合并
            </button>
            <button
              onClick={() => void doAction(() => edit("total_from_lines"))}
            >
              按明细计算总额
            </button>
          </div>
          {r.summary && (
            <div className="reconciliation">
              <span>明细合计 {money(r.summary.knownTotal, r.currency)}</span>
              <strong className={r.summary.difference ? "warning-text" : ""}>
                差额 {money(r.summary.difference, r.currency)}
              </strong>
            </div>
          )}
          <footer className="save-bar">
            <button
              disabled={busy}
              onClick={() => void doAction(() => save(false))}
            >
              {r.posted ? "保存修改" : "保存草稿"}
            </button>
            <button
              className="primary"
              disabled={busy}
              onClick={() =>
                void doAction(async () => {
                  const saved = await save(true);
                  if (saved) onBack();
                })
              }
            >
              {busy ? "正在保存…" : "确认并退出"}
            </button>
          </footer>
        </section>
      </div>
      {timeChoices && (
        <Modal title="确认重复的本地时间" onClose={() => setTimeChoices(null)}>
          <p>夏令时切换使这个时间出现两次，请选择实际交易时间。</p>
          {timeChoices.times.map((t) => (
            <button
              key={t}
              onClick={() => {
                update("occurredAt", t);
                update("timeSource", "user_entered");
                update("rawTime", timeChoices.text.replace("T", " "));
                setTimeChoices(null);
              }}
            >
              {date(t)} · UTC {new Date(t).toISOString()}
            </button>
          ))}
        </Modal>
      )}
      {line && (
        <LineEditor
          line={line}
          lines={r.lines}
          currency={r.currency}
          categories={loaded.data[2]}
          onClose={() => setLine(null)}
          onSave={(l) => {
            const exists = r.lines.some((a: Row) => a.id === l.id);
            update(
              "lines",
              exists
                ? r.lines.map((a: Row) => (a.id === l.id ? l : a))
                : [...r.lines, l],
            );
          }}
        />
      )}
      {photo && (
        <Modal title="收据照片" onClose={() => setPhoto(null)} wide>
          <img className="full-photo" src={photo} alt="完整收据" />
        </Modal>
      )}
      {storeEdit && (
        <Modal
          title="商店名称"
          onClose={() => {
            setStoreEdit(false);
            loaded.reload();
          }}
          wide
        >
          <Stores receiptId={id} suggested={r.store} />
        </Modal>
      )}
    </>
  );
}
function moneyDecimal(n: number, c: string) {
  return (
    n /
    10 ** (c === "JPY" || c === "KRW" ? 0 : c === "KWD" || c === "BHD" ? 3 : 2)
  ).toString();
}
function localInput(n: number) {
  const d = new Date(n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}T${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}
function CommitInput({
  label,
  value,
  options,
  onCommit,
}: {
  label: string;
  value: string;
  options: string[];
  onCommit: (v: string) => Promise<any>;
}) {
  const [text, setText] = useState(value),
    [busy, setBusy] = useState(false);
  const id = React.useId();
  useEffect(() => setText(value), [value]);
  async function commit() {
    if (text === value || busy) return;
    setBusy(true);
    try {
      await onCommit(text);
    } catch (e) {
      notify(String(e));
      setText(value);
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <input
        aria-label={label}
        value={text}
        list={id}
        disabled={busy}
        onChange={(e) => setText(e.target.value)}
        onBlur={() => void commit()}
        onKeyDown={(e) => {
          if (e.key === "Enter") e.currentTarget.blur();
        }}
        placeholder="选择或输入新的名称"
      />
      <datalist id={id}>
        {options.map((o) => (
          <option key={o} value={o} />
        ))}
      </datalist>
    </>
  );
}
function Catalog({
  onProduct,
}: {
  onProduct: (id: string, label: string) => void;
}) {
  const [tab, setTab] = useState(0),
    [search, setSearch] = useState(""),
    [category, setCategory] = useState<Row | null>(null);
  const data = useLoad(
    async () =>
      Promise.all([
        api.op("printed_names", "list"),
        api.op("product_names", "list"),
        api.op("categories", "list"),
      ]),
    [],
  );
  const tabs = ["票据名称", "商品名称", "商品分类", "商品种类"];
  async function save(f: () => Promise<any>) {
    await f();
    data.reload();
  }
  const filtered = (rows: Row[], field: string) =>
    rows.filter((r) => r[field].toLowerCase().includes(search.toLowerCase()));
  return (
    <>
      <Heading
        title="商品管理"
        subtitle="把不同商店的票面名称，整理为你熟悉的商品。"
      />
      <div className="tabs" role="tablist">
        {tabs.map((name, i) => (
          <button
            key={name}
            role="tab"
            aria-selected={tab === i}
            className={tab === i ? "active" : ""}
            onClick={() => setTab(i)}
          >
            {name}
          </button>
        ))}
      </div>
      <input
        className="search"
        aria-label="搜索商品"
        placeholder="搜索名称…"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />
      <StateView
        busy={!data.data && data.busy}
        error={data.error}
        onRetry={data.reload}
      />
      {data.data && (
        <>
          {(tab === 0 || tab === 2) &&
            (() => {
              const rows = filtered(
                  data.data[tab === 0 ? 0 : 1],
                  tab === 0 ? "raw_name" : "name",
                ),
                missing = (r: Row) =>
                  tab === 0
                    ? !r.product_name
                    : r.category_id === "00000000-0000-4000-8000-000000000001";
              return (
                <div className="mapping-list">
                  {[true, false].map((incomplete, index) => (
                    <React.Fragment key={String(incomplete)}>
                      {index === 1 &&
                        rows.some(missing) &&
                        rows.some((r) => !missing(r)) && (
                          <hr className="thin-separator" />
                        )}
                      {rows
                        .filter((r) => missing(r) === incomplete)
                        .map((r: Row) => (
                          <div
                            className="mapping"
                            key={r.printed_name_id || r.product_name_id}
                          >
                            <span>{tab === 0 ? r.raw_name : r.name}</span>
                            <CommitInput
                              label={`${tab === 0 ? r.raw_name : r.name}的${tab === 0 ? "商品名称" : "商品种类"}`}
                              value={
                                tab === 0
                                  ? r.product_name || ""
                                  : missing(r)
                                    ? ""
                                    : data.data[2].find(
                                        (c: Row) =>
                                          c.category_id === r.category_id,
                                      )?.path || r.category_name
                              }
                              options={
                                tab === 0
                                  ? data.data[1].map((n: Row) => n.name)
                                  : data.data[2].map((c: Row) => c.path)
                              }
                              onCommit={(v) =>
                                save(() =>
                                  tab === 0
                                    ? api.op(
                                        "printed_names",
                                        "set_product_name",
                                        {
                                          id: r.printed_name_id,
                                          name: v,
                                          expected_version: api.version,
                                        },
                                      )
                                    : api.op("product_names", "classify", {
                                        id: r.product_name_id,
                                        ...(v
                                          ? (() => {
                                              const c = data.data[2].find(
                                                (c: Row) => c.path === v,
                                              );
                                              return c
                                                ? { category_id: c.category_id }
                                                : { category_name: v };
                                            })()
                                          : {
                                              category_id:
                                                "00000000-0000-4000-8000-000000000001",
                                            }),
                                        expected_version: api.version,
                                      }),
                                )
                              }
                            />
                          </div>
                        ))}
                    </React.Fragment>
                  ))}
                </div>
              );
            })()}
          {tab === 1 && (
            <div className="tags">
              {filtered(data.data[1], "name").map((p: Row) => (
                <span className="tag" key={p.product_name_id}>
                  <button onClick={() => onProduct(p.product_name_id, p.name)}>
                    {p.name}
                  </button>
                  <IconButton
                    icon="close"
                    label={`删除商品名称 ${p.name}`}
                    onClick={() =>
                      void action(async () => {
                        if (confirm("解除该商品名称的所有关联？收据会保留。"))
                          await save(() =>
                            api.op("product_names", "delete", {
                              id: p.product_name_id,
                              expected_version: api.version,
                            }),
                          );
                      })
                    }
                  />
                </span>
              ))}
            </div>
          )}
          {tab === 3 && (
            <>
              <div className="tags">
                {filtered(data.data[2], "name").map((c: Row) => (
                  <span className="tag" key={c.category_id}>
                    <button
                      title="编辑名称与父类"
                      onClick={() => setCategory(c)}
                    >
                      {c.path}
                    </button>
                    {!c.system_key && (
                      <IconButton
                        icon="close"
                        label={`删除商品种类 ${c.name}`}
                        onClick={() =>
                          void action(async () => {
                            if (confirm("删除此种类？关联商品会变为未分类。"))
                              await save(() =>
                                api.op("categories", "delete", {
                                  id: c.category_id,
                                  expected_version: api.version,
                                }),
                              );
                          })
                        }
                      />
                    )}
                  </span>
                ))}
              </div>
              <button
                onClick={() =>
                  setCategory({ category_id: null, name: "", parent_id: null })
                }
              >
                <Icon name="add" />
                添加商品种类
              </button>
            </>
          )}
          {!data.data[tab === 0 ? 0 : tab === 3 ? 2 : 1].length && (
            <p className="muted">确认收据后，商品名称会出现在这里。</p>
          )}
        </>
      )}
      {category && (
        <CategoryForm
          value={category}
          categories={data.data[2]}
          onClose={() => setCategory(null)}
          onSave={async (value) => {
            await save(() =>
              api.op("categories", "save", {
                id: category.category_id,
                name: value.name,
                parent: value.parent,
                expected_version: api.version,
              }),
            );
            setCategory(null);
          }}
        />
      )}
    </>
  );
}
function CategoryForm({
  value,
  categories,
  onSave,
  onClose,
}: {
  value: Row;
  categories: Row[];
  onSave: (value: Row) => Promise<any>;
  onClose: () => void;
}) {
  const [name, setName] = useState(value.name),
    [parent, setParent] = useState(value.parent_id || ""),
    [busy, setBusy] = useState(false);
  return (
    <Modal
      title={value.category_id ? "编辑商品种类" : "添加商品种类"}
      onClose={onClose}
    >
      <form
        onSubmit={(e) => {
          e.preventDefault();
          setBusy(true);
          void action(() => onSave({ name, parent: parent || null })).finally(
            () => setBusy(false),
          );
        }}
      >
        <Field label="种类名称" value={name} onChange={setName} required />
        <Select
          label="父类"
          value={parent}
          onChange={setParent}
          options={[
            ["", "顶层分类"],
            ...categories
              .filter(
                (c) => c.category_id !== value.category_id && !c.parent_id,
              )
              .map((c): [string, string] => [c.category_id, c.name]),
          ]}
        />
        <footer>
          <button type="button" onClick={onClose}>
            取消
          </button>
          <button className="primary" disabled={busy}>
            保存
          </button>
        </footer>
      </form>
    </Modal>
  );
}
function Stores({
  receiptId = null,
  suggested = "",
}: {
  receiptId?: string | null;
  suggested?: string;
}) {
  const list = useLoad(
    () => api.op("logos", "list", { receipt_id: receiptId }),
    [receiptId],
  );
  const [busy, setBusy] = useState(false);
  async function mutate(f: () => Promise<any>) {
    if (busy) return;
    setBusy(true);
    try {
      await f();
      list.reload();
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      {!receiptId && (
        <Heading
          title="商店名称"
          subtitle="图像对应店名，识别不再依赖票面文字。"
        />
      )}
      {receiptId && (
        <button
          disabled={busy}
          onClick={() =>
            void action(() =>
              mutate(() =>
                api.op("logos", "extract", { receipt_id: receiptId }),
              ),
            )
          }
        >
          重新提取 Logo
        </button>
      )}
      <StateView
        busy={!list.data && list.busy}
        error={list.error}
        onRetry={list.reload}
      />
      <div className="store-grid">
        {list.data?.map((s: Row) => (
          <article key={s.logo_id}>
            <img
              src={`/api/v1/media/${s.media_id}`}
              alt={s.name || "尚未命名的商店标志"}
            />
            <CommitInput
              label="商店名称"
              value={s.name || ""}
              options={suggested ? [suggested] : []}
              onCommit={(name) =>
                mutate(() =>
                  api.op("logos", "save", {
                    id: s.logo_id,
                    name,
                    expected_version: api.version,
                  }),
                )
              }
            />
            {s.name && (
              <IconButton
                icon="trash"
                label="删除商店名称样本"
                disabled={busy}
                onClick={() =>
                  void action(async () => {
                    if (confirm("删除此商店名称样本？"))
                      await mutate(() =>
                        api.op("logos", "delete", {
                          id: s.logo_id,
                          expected_version: api.version,
                        }),
                      );
                  })
                }
              />
            )}
          </article>
        ))}
      </div>
      {list.data?.length === 0 && (
        <p className="muted">这张收据还没有提取到 Logo，可尝试重新提取。</p>
      )}
    </>
  );
}
const colors = [
  "#3159d9",
  "#d35b3b",
  "#29877d",
  "#8b5ac8",
  "#b18729",
  "#bd4c86",
];
export function TrendChart({
  data,
  visible,
  index,
  onSelect,
}: {
  data: Row;
  visible: Set<string>;
  index: number;
  onSelect: (i: number) => void;
}) {
  const points: Row[] = data.points,
    lines: Row[] = [
      { key: "total", label: "总金额", values: points.map((p) => p.net) },
      ...data.series,
    ].filter((s) => visible.has(s.key));
  const values = lines.flatMap((s) => s.values as number[]),
    min = Math.min(0, ...values),
    max = Math.max(1, ...values),
    x = (i: number) => 70 + (i * 860) / Math.max(1, points.length - 1),
    y = (n: number) => 235 - ((n - min) / (max - min)) * 200;
  return (
    <div className="chart-scroll">
      <svg
        className="trend-chart"
        viewBox="0 0 980 290"
        role="img"
        aria-label="消费趋势，可选择时间点查看明细"
      >
        {[0, 0.5, 1].map((v) => {
          const n = min + (max - min) * v;
          return (
            <g key={v}>
              <line
                x1="70"
                x2="935"
                y1={y(n)}
                y2={y(n)}
                className="grid-line"
              />
              <text x="60" y={y(n) + 4} textAnchor="end">
                {money(n, data.currency)}
              </text>
            </g>
          );
        })}
        <line
          x1={x(index)}
          x2={x(index)}
          y1="26"
          y2="235"
          className="selected-line"
        />
        {lines.map((s, k) => (
          <g key={s.key}>
            <polyline
              fill="none"
              stroke={colors[k % colors.length]}
              strokeWidth={s.key === "total" ? 3 : 2}
              points={s.values
                .map((n: number, i: number) => `${x(i)},${y(n)}`)
                .join(" ")}
            />
            {s.values.map((n: number, i: number) => (
              <circle
                key={i}
                cx={x(i)}
                cy={y(n)}
                r={i === index ? 5 : 3}
                fill={colors[k % colors.length]}
              />
            ))}
          </g>
        ))}
        {points.map((p, i) => (
          <g
            key={p.start}
            role="button"
            tabIndex={0}
            aria-label={`${p.label}，${money(p.net, data.currency)}`}
            onClick={() => onSelect(i)}
            onKeyDown={(e) => {
              if (e.key === "Enter" || e.key === " ") onSelect(i);
            }}
          >
            <rect
              x={x(i) - 18}
              y="20"
              width="36"
              height="255"
              fill="transparent"
            />
            <text
              x={x(i)}
              y="270"
              textAnchor="middle"
              className={i === index ? "selected-tick" : ""}
            >
              {p.tick}
            </text>
          </g>
        ))}
      </svg>
    </div>
  );
}
function Reports({ open }: { open: (id: string) => void }) {
  const [period, setPeriod] = useState("month"),
    [windowIndex, setWindow] = useState(0),
    [index, setIndex] = useState(-1),
    [visible, setVisible] = useState(new Set(["total"])),
    [category, setCategory] = useState<string | null>(null),
    [detail, setDetail] = useState<Row | null>(null),
    [seriesMenu, setSeriesMenu] = useState(false);
  const touch = useRef(0);
  const trend = useLoad(
    () =>
      api.op("reports", "trend", {
        period,
        window: windowIndex,
        anchor: Date.now(),
        zone,
        category,
      }),
    [period, windowIndex, category],
  );
  const selected =
    trend.data?.points[
      Math.max(
        0,
        index < 0
          ? trend.data.points.length - 1
          : Math.min(index, trend.data.points.length - 1),
      )
    ];
  const summary = useLoad(async () => {
    if (!selected) return null;
    let offset = 0;
    let result: Row | null = null;
    const entries: Row[] = [];
    do {
      const p = await api.op("reports", "summary", {
        start: selected.start,
        end: selected.end,
        zone,
        category,
        offset,
      });
      result ??= p;
      entries.push(...p.entries);
      offset = p.next_offset;
    } while (offset !== null);
    return { ...result, entries };
  }, [selected?.start, selected?.end, category]);
  const categories = useLoad(() => api.op("categories", "list"), []);
  function toggle(key: string) {
    setVisible((s) => {
      const n = new Set(s);
      if (n.has(key)) n.delete(key);
      else n.add(key);
      return n;
    });
  }
  return (
    <div
      onTouchStart={(e) => {
        touch.current = window.scrollY === 0 ? e.touches[0].clientY : 0;
      }}
      onTouchEnd={(e) => {
        if (touch.current && e.changedTouches[0].clientY - touch.current > 70) {
          trend.reload();
          summary.reload();
        }
        touch.current = 0;
      }}
    >
      <Heading
        title="报表"
        subtitle="从每一次消费，看见长时间的变化。"
        action={
          <IconButton
            icon="refresh"
            label="重新统计并刷新报表"
            onClick={() => {
              trend.reload();
              summary.reload();
            }}
          />
        }
      />
      <div className="report-controls">
        <div className="segmented">
          {Object.entries({
            day: "日",
            week: "周",
            month: "月",
            quarter: "季",
            year: "年",
          }).map(([key, name]) => (
            <button
              key={key}
              className={period === key ? "active" : ""}
              onClick={() => {
                setPeriod(key);
                setIndex(-1);
                setWindow(0);
              }}
            >
              {name}
            </button>
          ))}
        </div>
        <span className="spacer" />
        <button
          onClick={() => {
            setWindow((w) => Math.max(-100, w - 1));
            setIndex(-1);
          }}
        >
          ← 更早
        </button>
        <button
          disabled={windowIndex === 0}
          onClick={() => {
            setWindow((w) => Math.min(0, w + 1));
            setIndex(-1);
          }}
        >
          较近 →
        </button>
        <button onClick={() => setSeriesMenu(!seriesMenu)}>曲线选择</button>
      </div>
      <StateView
        busy={!trend.data && trend.busy}
        error={trend.error}
        onRetry={trend.reload}
      />
      {seriesMenu && (
        <div className="series-menu">
          {[
            { key: "total", label: "总金额" },
            ...(trend.data?.series || []),
          ].map((s: Row) => (
            <label className="check" key={s.key}>
              <input
                type="checkbox"
                checked={visible.has(s.key)}
                onChange={() => toggle(s.key)}
              />
              {s.label}
            </label>
          ))}
        </div>
      )}
      {trend.data && (
        <TrendChart
          data={trend.data}
          visible={visible}
          index={Math.max(0, index < 0 ? trend.data.points.length - 1 : index)}
          onSelect={setIndex}
        />
      )}
      <div className="section-heading">
        <h2>{selected?.label || "当前期间"}</h2>
        {category && (
          <button onClick={() => setCategory(null)}>返回所有分类</button>
        )}
      </div>
      <StateView
        error={summary.error}
        busy={!summary.data && summary.busy}
        onRetry={summary.reload}
      />
      {summary.data && (
        <>
          <div className="report-summary">
            {[
              ["net", "总支出"],
              ["discounts", "优惠"],
              ["refunds", "退款"],
            ].map(([key, label]) => (
              <div key={key}>
                <span>{label}</span>
                <strong>
                  {money(summary.data[key], summary.data.currency)}
                </strong>
              </div>
            ))}
          </div>
          {summary.data.difference !== 0 && summary.data.difference != null && (
            <p className="notice">
              明细与票面金额差额：
              {money(summary.data.difference, summary.data.currency)}
            </p>
          )}
          <div className="report-groups">
            {["category", "product"].map((group) => (
              <section key={group}>
                <h2>{group === "category" ? "商品分类" : "商品"}</h2>
                {summary.data.groups
                  .filter((g: Row) => g.group === group)
                  .map((g: Row) => (
                    <button
                      className="group-row"
                      key={g.key}
                      onClick={() => {
                        if (group === "category") {
                          const key = g.key.slice(9);
                          if (
                            categories.data?.some(
                              (c: Row) => c.parent_id === key,
                            )
                          )
                            setCategory(key);
                          else setDetail(g);
                        } else setDetail(g);
                      }}
                    >
                      <span>
                        {g.label}
                        <small>{g.quantity_labels.join(" · ")}</small>
                      </span>
                      <strong>{money(g.amount, summary.data.currency)}</strong>
                    </button>
                  ))}
                {!summary.data.entries.length && (
                  <p className="muted">此期间没有已确认的消费明细。</p>
                )}
              </section>
            ))}
          </div>
        </>
      )}
      {detail && (
        <Modal title={detail.label} onClose={() => setDetail(null)} wide>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>商品</th>
                  <th>商店</th>
                  <th>收据时间</th>
                  <th>金额</th>
                </tr>
              </thead>
              <tbody>
                {summary.data.entries
                  .filter((e: Row) => detail.line_ids.includes(e.line_id))
                  .map((e: Row) => (
                    <tr key={e.line_id}>
                      <td>
                        <button
                          className="row-link"
                          onClick={() => open(e.receipt_id)}
                        >
                          {e.product_name || e.raw_name}
                        </button>
                      </td>
                      <td>{e.raw_store || "未知商店"}</td>
                      <td>{date(e.occurred_at_utc_ms)}</td>
                      <td>{money(e.amount_minor, summary.data.currency)}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        </Modal>
      )}
    </div>
  );
}
function Settings({
  theme,
  setTheme,
  onChangePassword,
}: {
  theme: string;
  setTheme: (v: string) => void;
  onChangePassword: () => void;
}) {
  const preferences = useLoad(() => api.op("config", "get"), []);
  const [busy, setBusy] = useState(false);
  const restoreFile = useRef<HTMLInputElement>(null);
  async function run(f: () => Promise<any>) {
    setBusy(true);
    try {
      await f();
    } finally {
      setBusy(false);
    }
  }
  async function exported(op: string) {
    const value = await api.op("exports", op, op === "csv" ? { zone } : {});
    if (op === "csv")
      download("receipt-items.csv", value, "text/csv;charset=utf-8");
    else
      download(
        `${op}-${Date.now()}.receiptbackup`,
        decode64(value.bytes_base64),
        "application/zip",
      );
  }
  return (
    <>
      <Heading title="设置" subtitle="统一显示方式，管理属于你的数据。" />
      <StateView error={preferences.error} onRetry={preferences.reload} />
      <section className="settings-section">
        <h2>外观与偏好</h2>
        <Select
          label="主题"
          value={theme}
          onChange={setTheme}
          options={[
            ["system", "跟随系统"],
            ["light", "浅色"],
            ["dark", "深色"],
          ]}
        />
        {preferences.data && (
          <>
            <Select
              label="全局重量显示单位"
              value={preferences.data.weight_unit}
              options={["g", "kg", "lb", "oz"].map((u) => [u, u])}
              onChange={(v) =>
                void action(() =>
                  run(async () => {
                    await api.op("config", "save_weight_unit", {
                      weight_unit: v,
                      expected_version: api.version,
                    });
                    preferences.reload();
                  }),
                )
              }
            />
            <Select
              label="报表显示币种 · 按交易日汇率统一换算"
              value={preferences.data.report_currency}
              options={currencies.map((c) => [c, c])}
              onChange={(v) =>
                void action(() =>
                  run(async () => {
                    await api.op("config", "save_report_currency", {
                      report_currency: v,
                      expected_version: api.version,
                    });
                    preferences.reload();
                  }),
                )
              }
            />
          </>
        )}
        <p className="muted">时间按当前时区 {zone} 显示；数据库统一存 UTC。</p>
      </section>
      <section className="settings-section">
        <h2>账户</h2>
        <p>
          {api.user?.username}{" "}
          {api.user?.is_admin && <span className="badge">元用户</span>}
        </p>
        <div className="inline-actions">
          <button onClick={onChangePassword}>修改密码</button>
          <button onClick={() => void action(() => api.logout())}>
            <Icon name="logout" />
            退出登录
          </button>
        </div>
      </section>
      <section className="settings-section">
        <h2>数据</h2>
        <p className="muted">
          备份包含本账户的收据、草稿与照片，不含身份库或其他用户的数据。
        </p>
        <div className="data-actions">
          {[
            ["create_backup", "导出完整备份"],
            ["latest_backup", "导出最近恢复点"],
            ["csv", "导出明细 CSV"],
          ].map(([op, label]) => (
            <button
              key={op}
              disabled={busy}
              onClick={() => void action(() => run(() => exported(op)))}
            >
              {label}
            </button>
          ))}
          <button disabled={busy} onClick={() => restoreFile.current?.click()}>
            从备份整体恢复
          </button>
          <button disabled={busy} onClick={() => void action(retry)}>
            重试未完成上传
          </button>
          <AndroidDownloadLink className="button" />
        </div>
        <input
          type="file"
          ref={restoreFile}
          hidden
          accept=".receiptbackup,.zip"
          onChange={(e) => {
            const file = e.target.files?.[0];
            e.target.value = "";
            if (
              file &&
              confirm(
                "备份会替换本账户当前收据和照片，后端将先保存恢复点。继续？",
              )
            )
              void action(() =>
                run(async () => {
                  const p = await api.op("maintenance", "prepare_restore", {
                    bytes_base64: await encode64(file),
                  });
                  await api.op("maintenance", "commit_restore", {
                    token: p.token,
                    confirm: true,
                  });
                  preferences.reload();
                  notify("备份已恢复");
                }),
              );
          }}
        />
      </section>
    </>
  );
}
export function Users() {
  const list = useLoad(() => api.auth("users", undefined, "GET"), []);
  const [show, setShow] = useState(false),
    [name, setName] = useState(""),
    [password, setPassword] = useState(""),
    [busy, setBusy] = useState(false);
  return (
    <>
      <Heading
        title="用户管理"
        subtitle="只有元用户 admin 可以创建和删除用户。"
        action={
          <button className="primary" onClick={() => setShow(true)}>
            <Icon name="add" />
            创建用户
          </button>
        }
      />
      <StateView
        busy={!list.data && list.busy}
        error={list.error}
        onRetry={list.reload}
      />
      <table>
        <thead>
          <tr>
            <th>用户名</th>
            <th>权限</th>
            <th>密码状态</th>
            <th>操作</th>
          </tr>
        </thead>
        <tbody>
          {list.data?.map((u: User) => (
            <tr key={u.user_id}>
              <td>{u.username}</td>
              <td>{u.is_admin ? "元用户" : "普通用户"}</td>
              <td>{u.must_change_password ? "首次登录需改密" : "已设置"}</td>
              <td>
                {u.is_admin ? (
                  <span className="muted">不可删除</span>
                ) : (
                  <IconButton
                    icon="trash"
                    label={`删除用户 ${u.username}`}
                    onClick={() =>
                      void action(async () => {
                        if (
                          confirm(`删除 ${u.username} 及其全部收据和照片？`)
                        ) {
                          await api.auth(
                            `users/${u.user_id}`,
                            undefined,
                            "DELETE",
                          );
                          list.reload();
                        }
                      })
                    }
                  />
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {show && (
        <Modal title="创建用户" onClose={() => setShow(false)}>
          <form
            id="create-user-form"
            name="create-user"
            action="/api/auth/users"
            method="post"
            autoComplete="on"
            onSubmit={(e) => {
              e.preventDefault();
              const values = new FormData(e.currentTarget);
              const username = String(values.get("username") ?? "");
              const temporaryPassword = String(
                values.get("new-password") ?? "",
              );
              setName(username);
              setPassword(temporaryPassword);
              setBusy(true);
              void action(async () => {
                await api.auth("users", {
                  username,
                  password: temporaryPassword,
                });
                setName("");
                setPassword("");
                setShow(false);
                list.reload();
              }).finally(() => setBusy(false));
            }}
          >
            <Field
              label="用户名"
              id="create-user-username"
              name="username"
              value={name}
              onChange={setName}
              required
              autoComplete="section-created-user username"
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              pattern="[A-Za-z0-9._-]{3,64}"
            />
            <Field
              label="临时密码 · 至少 12 个字符"
              id="create-user-password"
              name="new-password"
              value={password}
              onChange={setPassword}
              required
              minLength={12}
              type="password"
              autoComplete="section-created-user new-password"
            />
            <p className="muted">用户首次登录必须更改这个临时密码。</p>
            <footer>
              <button type="button" onClick={() => setShow(false)}>
                取消
              </button>
              <button className="primary" disabled={busy}>
                创建
              </button>
            </footer>
          </form>
        </Modal>
      )}
    </>
  );
}
function Workspace() {
  const [page, setPage] = useState("receipts"),
    [drawer, setDrawer] = useState(false),
    [camera, setCamera] = useState(false),
    [editor, setEditor] = useState<string | null>(null),
    [product, setProduct] = useState<Row | null>(null),
    [theme, setThemeValue] = useState(
      localStorage.getItem("theme") || "system",
    ),
    [change, setChange] = useState(false),
    [notice, setNotice] = useState("");
  const upload = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const handler = (e: Event) => setNotice((e as CustomEvent).detail);
    window.addEventListener("notice", handler);
    void retry().catch((e) => notify(String(e)));
    return () => window.removeEventListener("notice", handler);
  }, []);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("theme", theme);
  }, [theme]);
  async function manual() {
    const result = await api.op("receipts", "create", {
      receipt: emptyReceipt(),
    });
    setEditor(result.id);
  }
  function navigate(key: string) {
    if (editor && !confirm("退出收据编辑？请先保存尚未保存的修改。")) return;
    setEditor(null);
    setProduct(null);
    setPage(key);
    setDrawer(false);
  }
  return (
    <>
      <div className="toolbar">
        <IconButton
          icon="menu"
          label="打开导航菜单"
          onClick={() => setDrawer(!drawer)}
        />
        <a
          className="wordmark"
          href="/"
          onClick={(e) => {
            e.preventDefault();
            navigate("receipts");
          }}
        >
          Receipt Master
        </a>
        <span className="spacer" />
        {page === "receipts" && !editor && (
          <>
            <IconButton
              icon="camera"
              label="拍照"
              onClick={() => setCamera(true)}
            />
            <IconButton
              icon="upload"
              label="上传照片"
              onClick={() => upload.current?.click()}
            />
            <IconButton
              icon="add"
              label="手动录入"
              onClick={() => void action(manual)}
            />
          </>
        )}
        <span className="account-label">{api.user?.username}</span>
      </div>
      <input
        hidden
        type="file"
        ref={upload}
        accept="image/jpeg,image/png,image/webp"
        multiple
        onChange={(e) => {
          const files = Array.from(e.target.files || []);
          e.target.value = "";
          if (files.length)
            void action(async () => {
              await enqueue(files, false);
              notify("已开始上传，上传完自动识别。");
            });
        }}
      />
      {drawer && (
        <>
          <button
            className="drawer-shade"
            aria-label="关闭导航菜单"
            onClick={() => setDrawer(false)}
          />
          <nav className="drawer" aria-label="主导航">
            <div className="drawer-brand">
              <Icon name="receipt" />
              <strong>Receipt Master</strong>
            </div>
            {Object.entries(names)
              .filter(([key]) => key !== "users" || api.user?.is_admin)
              .map(([key, label]) => (
                <button
                  key={key}
                  className={page === key ? "active" : ""}
                  onClick={() => navigate(key)}
                >
                  <Icon name={key} />
                  {label}
                </button>
              ))}
            <AndroidDownloadLink className="android-download" />
            <small>{api.user?.username} · 私人数据空间</small>
          </nav>
        </>
      )}
      <main className="workspace">
        {notice && (
          <div className="notice toast" role="status">
            <span>{notice}</span>
            <IconButton
              icon="close"
              label="关闭提示"
              onClick={() => setNotice("")}
            />
          </div>
        )}
        {editor ? (
          <Editor id={editor} onBack={() => setEditor(null)} />
        ) : page === "receipts" ? (
          <>
            {product && (
              <button onClick={() => setProduct(null)}>← 所有收据</button>
            )}
            <Receipts
              open={setEditor}
              productId={product?.id}
              title={product ? `商品 · ${product.label}` : "收据"}
            />
          </>
        ) : page === "catalog" ? (
          <Catalog
            onProduct={(id, label) => {
              setProduct({ id, label });
              setPage("receipts");
            }}
          />
        ) : page === "stores" ? (
          <Stores />
        ) : page === "reports" ? (
          <Reports open={setEditor} />
        ) : page === "users" ? (
          <Users />
        ) : (
          <Settings
            theme={theme}
            setTheme={setThemeValue}
            onChangePassword={() => setChange(true)}
          />
        )}
      </main>
      {camera && <Camera onClose={() => setCamera(false)} />}{" "}
      {change && (
        <Modal title="修改密码" onClose={() => setChange(false)}>
          <SignIn change onDone={() => setChange(false)} />
        </Modal>
      )}
    </>
  );
}
export function App() {
  const [user, setUser] = useState<User | null>(null),
    [boot, setBoot] = useState(true);
  useEffect(() => {
    api.onUser = setUser;
    void api
      .refresh()
      .catch(() => {})
      .finally(() => setBoot(false));
    return () => {
      api.onUser = () => {};
    };
  }, []);
  if (boot) return <StateView busy />;
  if (!user) return <SignIn />;
  if (user.must_change_password) return <SignIn change />;
  return <Workspace key={user.user_id} />;
}
