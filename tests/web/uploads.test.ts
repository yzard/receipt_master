// @vitest-environment jsdom
import "fake-indexeddb/auto";
import { Blob as NativeBlob } from "node:buffer";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { api } from "../../src/web/src/api";
import { enqueue, pending, resume } from "../../src/web/src/uploads";
beforeEach(() => {
  const browserCrypto = globalThis.crypto;
  vi.stubGlobal("Blob", NativeBlob);
  vi.stubGlobal("crypto", {
    getRandomValues: browserCrypto.getRandomValues.bind(browserCrypto),
  });
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
describe("durable multi-photo uploads", () => {
  it("replays exactly the same upload input after a lost server response", async () => {
    api.user = {
      user_id: "upload-alice",
      username: "alice",
      is_admin: false,
      must_change_password: false,
    };
    const op = vi
      .spyOn(api, "op")
      .mockImplementation(async (_c, action, input) =>
        action === "create"
          ? { ...input?.receipt, revision: 1 }
          : action === "get"
            ? { id: "receipt", revision: 1 }
            : {},
      );
    const upload = vi
      .spyOn(api, "upload")
      .mockRejectedValueOnce(new TypeError("response lost"));
    await enqueue([new Blob(["one"]), new Blob(["two"])], true);
    await vi.waitFor(async () =>
      expect((await pending())[0]?.error).toContain("response lost"),
    );
    const stopped = (await pending())[0];
    const firstInput = upload.mock.calls[0];
    upload.mockImplementation(async (receipt) => ({
      receipt: { ...receipt, revision: receipt.revision + 1 },
    }));
    await resume(stopped);
    expect(upload.mock.calls[1]).toEqual(firstInput);
    expect(upload).toHaveBeenCalledTimes(3);
    expect(op.mock.calls.filter((c) => c[1] === "get")).toHaveLength(2);
    expect(op.mock.calls.at(-1)?.[1]).toBe("start");
    expect(await pending()).toHaveLength(0);
  });
  it("pauses before uploading any photo under a different account", async () => {
    api.user = {
      user_id: "upload-alice",
      username: "alice",
      is_admin: false,
      must_change_password: false,
    };
    const op = vi.spyOn(api, "op").mockRejectedValue(new TypeError("offline"));
    const upload = vi.spyOn(api, "upload");
    await enqueue([new Blob(["private"])], false);
    await vi.waitFor(async () =>
      expect((await pending())[0]?.error).toContain("offline"),
    );
    const stopped = (await pending())[0];
    api.user = { ...api.user!, user_id: "upload-bob" };
    expect(await pending()).toHaveLength(0);
    op.mockClear();
    await resume(stopped);
    expect(upload).not.toHaveBeenCalled();
    expect(op).not.toHaveBeenCalled();
  });
});
