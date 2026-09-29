import { api, emptyReceipt, zone, Row } from "./api";
import { newId } from "./id";
export type Submission = {
  id: string;
  userId: string;
  photos: Blob[];
  camera: boolean;
  receipt: Row;
  position: number;
  error?: string;
  uploadInput?: { receipt: Row; capturedAt: number | null };
};
let opening: Promise<IDBDatabase> | null = null;
function database() {
  return (opening ??= new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open("receipt-master-uploads", 1);
    request.onupgradeneeded = () =>
      request.result.createObjectStore("submissions", { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }));
}
async function change(value: Submission | string) {
  const db = await database();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction("submissions", "readwrite");
    const s = tx.objectStore("submissions");
    if (typeof value === "string") s.delete(value);
    else s.put(value);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
  window.dispatchEvent(new Event("submissions"));
}
export async function pending(): Promise<Submission[]> {
  const db = await database();
  return new Promise((resolve, reject) => {
    const r = db.transaction("submissions").objectStore("submissions").getAll();
    r.onsuccess = () =>
      resolve(
        r.result.filter((s: Submission) => s.userId === api.user?.user_id),
      );
    r.onerror = () => reject(r.error);
  });
}
const running = new Set<string>();
export async function resume(s: Submission) {
  if (running.has(s.id)) return;
  running.add(s.id);
  try {
    const check = () => {
      if (api.user?.user_id !== s.userId)
        throw new Error("账户已变更，上传已暂停");
    };
    check();
    if (!s.receipt.revision) {
      s.receipt = await api.op(
        "receipts",
        "create",
        { receipt: s.receipt },
        `${s.id}-create`,
      );
      await change(s);
    }
    while (s.position < s.photos.length) {
      check();
      if (!s.uploadInput) {
        s.uploadInput = {
          receipt: await api.op("receipts", "get", { id: s.receipt.id }),
          capturedAt: s.camera ? Date.now() : null,
        };
        await change(s);
      }
      const uploaded = await api.upload(
        s.uploadInput.receipt,
        s.photos[s.position],
        s.camera,
        `${s.id}-${s.position}`,
        s.uploadInput.capturedAt,
      );
      s.receipt = uploaded.receipt;
      s.position++;
      delete s.uploadInput;
      delete s.error;
      await change(s);
    }
    check();
    await api.op(
      "recognition",
      "start",
      { receipt_id: s.receipt.id, expected_version: s.receipt.revision, zone },
      `${s.id}-recognize`,
    );
    await change(s.id);
  } catch (e) {
    s.error = String(e);
    await change(s);
  } finally {
    running.delete(s.id);
    window.dispatchEvent(new Event("submissions"));
  }
}
export async function enqueue(photos: Blob[], camera: boolean) {
  if (!api.user || !photos.length) return;
  const s: Submission = {
    id: newId(),
    userId: api.user.user_id,
    photos,
    camera,
    receipt: emptyReceipt(),
    position: 0,
  };
  await change(s);
  void resume(s);
}
export async function retry() {
  for (const s of await pending()) void resume(s);
}
