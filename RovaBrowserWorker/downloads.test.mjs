import { test } from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { mkdtemp, readFile, rm, readdir, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { saveDocumentDownload } from "./downloads.mjs";
const task = "11111111-1111-4111-8111-111111111111";
function download(name, bytes) {
  return { suggestedFilename: () => name, createReadStream: async () => Readable.from([bytes]), failure: async () => null, cancel: async () => {}, delete: async () => {} };
}
test("download has real bytes and digest; repeated name never overwrites", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "wiqo-download-")));
  try {
    const bytes = Buffer.from("%PDF-1.7\nfixture\n");
    const first = await saveDocumentDownload(download("rapor.pdf", bytes), root, task);
    const second = await saveDocumentDownload(download("rapor.pdf", bytes), root, task);
    assert.notEqual(first.path, second.path);
    assert.deepEqual(await readFile(first.path), bytes);
    assert.equal(first.sha256, createHash("sha256").update(bytes).digest("hex"));
    assert.equal(first.byteCount, bytes.length);
  } finally { await rm(root, { recursive: true }); }
});
test("HTML masquerading as PDF and executable extensions fail without residue", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "wiqo-download-")));
  try {
    await assert.rejects(saveDocumentDownload(download("login.pdf", Buffer.from("<html>Login</html>")), root, task), { code: "BROWSER_DOWNLOAD_TYPE_BLOCKED" });
    assert.deepEqual(await readdir(join(root, "downloads", task)), []);
    await assert.rejects(saveDocumentDownload(download("run.exe", Buffer.from("MZ")), root, task), { code: "BROWSER_DOWNLOAD_TYPE_BLOCKED" });
  } finally { await rm(root, { recursive: true }); }
});
test("over-limit stream fails and removes partial bytes", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "wiqo-download-")));
  try {
    await assert.rejects(saveDocumentDownload(download("huge.txt", Buffer.alloc(26 * 1024 * 1024)), root, task), { code: "BROWSER_DOWNLOAD_TOO_LARGE" });
    assert.deepEqual(await readdir(join(root, "downloads", task)), []);
  } finally { await rm(root, { recursive: true }); }
});
test("long names retain the extension required by the document adapter", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "wiqo-download-")));
  try {
    const result = await saveDocumentDownload(download("a".repeat(200) + ".pdf", Buffer.from("%PDF-1.7\nfixture")), root, task);
    assert.ok(result.path.endsWith(".pdf"));
  } finally { await rm(root, { recursive: true }); }
});
test("bounded HTTP stream pins DNS and validates each redirect", async () => {
  const { createServer } = await import("node:http");
  const { fetchDocumentDownload } = await import("./downloads.mjs");
  const root = await realpath(await mkdtemp(join(tmpdir(), "wiqo-download-")));
  const server = createServer((request, response) => {
    if (request.url === "/redirect") { response.writeHead(302, { location: "/document" }); response.end(); }
    else if (request.url === "/private") { response.writeHead(302, { location: "http://blocked.invalid/private" }); response.end(); }
    else { response.writeHead(200); response.end("%PDF-1.7\nVerified public document."); }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const port = server.address().port;
    const resolver = async () => ({ address: "127.0.0.1", family: 4 });
    const allowed = (url) => new URL(url).hostname === "public.invalid";
    const response = await fetchDocumentDownload(`http://public.invalid:${port}/redirect`, "a.pdf", resolver, allowed, AbortSignal.timeout(2000));
    const saved = await saveDocumentDownload(response, root, task);
    assert.match((await readFile(saved.path)).toString(), /Verified public document/);
    await assert.rejects(fetchDocumentDownload(`http://public.invalid:${port}/private`, "a.pdf", resolver, allowed, AbortSignal.timeout(2000)), { code: "BROWSER_NETWORK_BLOCKED" });
  } finally { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); await rm(root, { recursive: true }); }
});
