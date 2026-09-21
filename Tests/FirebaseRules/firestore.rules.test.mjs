import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  Bytes,
  Timestamp,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
} from "firebase/firestore";

const projectId = "demo-myterm";
const rules = await readFile(new URL("../../firestore.rules", import.meta.url), "utf8");

let testEnvironment;

test.before(async () => {
  testEnvironment = await initializeTestEnvironment({
    projectId,
    firestore: {
      host: "127.0.0.1",
      port: Number(process.env.FIRESTORE_EMULATOR_HOST?.split(":").at(-1) || 8080),
      rules,
    },
  });
});

test.after(async () => {
  await testEnvironment?.cleanup();
});

test("未登入使用者無法讀取或建立任何文件", async () => {
  const database = testEnvironment.unauthenticatedContext().firestore();
  const target = doc(database, "users/anonymous/vaultKeys/current");

  await assertFails(getDoc(target));
  await assertFails(setDoc(target, validEnvelope()));
});

test("登入者只能讀寫自己的固定加密封套文件", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  const envelope = doc(database, "users/alice/vaultKeys/current");

  await setDoc(envelope, validEnvelope());
  await getDoc(envelope);
  await updateDoc(envelope, validEnvelope(Bytes.fromUint8Array(new Uint8Array([4, 5, 6]))));
  await assertFails(deleteDoc(envelope));
});

test("已登入使用者無法跨帳號讀寫", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  const otherUserRecord = doc(database, "users/bob/vaultKeys/current");

  await assertFails(getDoc(otherUserRecord));
  await assertFails(setDoc(otherUserRecord, validEnvelope()));
});

test("其他 Firestore 路徑仍全部拒絕", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  await assertFails(setDoc(doc(database, "users/alice"), { schemaVersion: 1 }));
  await assertFails(setDoc(doc(database, "users/alice/vault/record-1"), validEnvelope()));
  await assertFails(setDoc(doc(database, "users/alice/vaultKeys/not-current"), validEnvelope()));
});

test("加密封套嚴格限制欄位、類型、版本與大小", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  const target = doc(database, "users/alice/vaultKeys/current");

  await assertFails(setDoc(target, { ...validEnvelope(), unexpected: true }));
  await assertFails(setDoc(target, { ...validEnvelope(), documentType: "host" }));
  await assertFails(setDoc(target, { ...validEnvelope(), schemaVersion: 2 }));
  await assertFails(setDoc(target, { ...validEnvelope(), payload: "base64-is-not-bytes" }));
  await assertFails(setDoc(target, validEnvelope(Bytes.fromUint8Array(new Uint8Array()))));
  await assertFails(setDoc(
    target,
    validEnvelope(Bytes.fromUint8Array(new Uint8Array(65537))),
  ));
});

function validEnvelope(payload = Bytes.fromUint8Array(new Uint8Array([1, 2, 3]))) {
  return {
    documentType: "vaultKeyEnvelope",
    schemaVersion: 1,
    payload,
  };
}

test("登入者只能列出與寫入自己 UID 下的加密主機／群組紀錄", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  const host = doc(database, "users/alice/vault/10000000-2000-3000-4000-500000000001");
  const group = doc(database, "users/alice/vault/10000000-2000-3000-4000-500000000002");

  await setDoc(host, validMetadataRecord("host"));
  await setDoc(group, validMetadataRecord("group"));
  await getDoc(host);
  await getDocs(collection(database, "users/alice/vault"));
  await assertFails(deleteDoc(host));
});

test("加密主機／群組／密碼紀錄允許自己的 UID，並拒絕跨 UID 與錯誤欄位", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  const own = doc(database, "users/alice/vault/20000000-2000-3000-4000-500000000001");
  const ownPassword = doc(database, "users/alice/vault/20000000-2000-3000-4000-500000000003");
  const other = doc(database, "users/bob/vault/20000000-2000-3000-4000-500000000002");

  await assertFails(setDoc(other, validMetadataRecord("host")));
  await assertFails(getDoc(other));
  await assertSucceeds(setDoc(ownPassword, validMetadataRecord("password")));
  await assertFails(setDoc(own, validMetadataRecord("privateKey")));
  await assertFails(setDoc(own, { ...validMetadataRecord("host"), hostname: "must-not-be-plaintext" }));
  await assertFails(setDoc(own, { ...validMetadataRecord("host"), revision: 0 }));
  await assertFails(setDoc(own, { ...validMetadataRecord("host"), nonce: Bytes.fromUint8Array(new Uint8Array(11)) }));
  await assertFails(setDoc(own, { ...validMetadataRecord("host"), authenticationTag: Bytes.fromUint8Array(new Uint8Array(15)) }));
  await assertFails(setDoc(
    own,
    { ...validMetadataRecord("host"), ciphertext: Bytes.fromUint8Array(new Uint8Array(65537)) },
  ));
});

test("刪除同步紀錄只能使用空密文 tombstone", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  const target = doc(database, "users/alice/vault/30000000-2000-3000-4000-500000000001");

  await setDoc(target, validMetadataRecord("host"));
  await setDoc(target, validMetadataRecord("host", true, 2));
  await assertFails(setDoc(target, { ...validMetadataRecord("host"), ciphertext: Bytes.fromUint8Array(new Uint8Array()) }));
  await assertFails(setDoc(target, { ...validMetadataRecord("host", true, 2), ciphertext: Bytes.fromUint8Array(new Uint8Array([9])) }));
});

test("加密紀錄只能從 revision 1 建立並逐次加一", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  const target = doc(database, "users/alice/vault/40000000-2000-3000-4000-500000000001");

  await assertFails(setDoc(target, validMetadataRecord("host", false, 2)));
  await setDoc(target, validMetadataRecord("host", false, 1));
  await assertFails(setDoc(target, validMetadataRecord("host", false, 1)));
  await assertFails(setDoc(target, validMetadataRecord("host", false, 3)));
  await setDoc(target, validMetadataRecord("host", false, 2));
  await assertFails(setDoc(target, validMetadataRecord("group", false, 3)));
  await assertFails(setDoc(target, { ...validMetadataRecord("host", false, 3), keyVersion: 2 }));
  await assertFails(setDoc(target, { ...validMetadataRecord("host", false, 3), formatVersion: 2 }));
  await setDoc(target, validMetadataRecord("host", true, 3));
});

test("連線稽核密文只能由自己的 UID 建立與讀取，且建立後不可更新", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  const own = doc(database, "users/alice/connectionLogs/50000000-2000-3000-4000-500000000001");
  const other = doc(database, "users/bob/connectionLogs/50000000-2000-3000-4000-500000000002");

  await assertSucceeds(setDoc(own, validConnectionAuditRecord()));
  await assertSucceeds(getDoc(own));
  await assertSucceeds(getDocs(collection(database, "users/alice/connectionLogs")));
  await assertFails(updateDoc(own, validConnectionAuditRecord(
    Bytes.fromUint8Array(new Uint8Array([4, 5, 6])),
  )));
  await assertFails(setDoc(other, validConnectionAuditRecord()));
  await assertFails(getDoc(other));
});

test("連線稽核只接受固定欄位密文，刪除權限只供到期整理", async () => {
  const database = testEnvironment.authenticatedContext("alice").firestore();
  const target = doc(database, "users/alice/connectionLogs/60000000-2000-3000-4000-500000000001");

  await assertFails(setDoc(target, { ...validConnectionAuditRecord(), hostname: "must-not-be-plaintext" }));
  await assertFails(setDoc(target, { ...validConnectionAuditRecord(), recordType: "host" }));
  await assertFails(setDoc(target, validConnectionAuditRecord(Bytes.fromUint8Array(new Uint8Array()))));
  await assertFails(setDoc(target, {
    ...validConnectionAuditRecord(),
    nonce: Bytes.fromUint8Array(new Uint8Array(11)),
  }));
  await setDoc(target, validConnectionAuditRecord());
  await assertSucceeds(deleteDoc(target));
});

function validMetadataRecord(recordType, deleted = false, revision = 1) {
  return {
    recordType,
    ciphertext: Bytes.fromUint8Array(deleted ? new Uint8Array() : new Uint8Array([7, 8, 9])),
    nonce: Bytes.fromUint8Array(new Uint8Array(12)),
    authenticationTag: Bytes.fromUint8Array(new Uint8Array(16)),
    keyVersion: 1,
    formatVersion: 1,
    revision,
    modifiedAt: Timestamp.fromMillis(1_700_000_000_000),
    modifiedByDeviceID: "90000000-8000-7000-6000-500000000001",
    deleted,
  };
}

function validConnectionAuditRecord(
  ciphertext = Bytes.fromUint8Array(new Uint8Array([1, 2, 3])),
) {
  return {
    recordType: "connectionAudit",
    ciphertext,
    nonce: Bytes.fromUint8Array(new Uint8Array(12)),
    authenticationTag: Bytes.fromUint8Array(new Uint8Array(16)),
    keyVersion: 1,
    formatVersion: 1,
  };
}


test("常用指令隔離集合：owner、版本、刪除與密文界線", async () => {
  const db = testEnvironment.authenticatedContext("snippet-alice").firestore();
  const id = "70000000-2000-3000-4000-500000000001";
  const ref = doc(db, `users/snippet-alice/commandSnippets/${id}`);
  const valid = (deleted = false, revision = 1) => validMetadataRecord("commandSnippet", deleted, revision);
  await assertFails(setDoc(ref, { ...valid(), command: "plaintext" }));
  await assertFails(setDoc(ref, { ...valid(), ciphertext: Bytes.fromUint8Array(new Uint8Array(131073)) }));
  await assertFails(setDoc(ref, { ...valid(), formatVersion: 2 }));
  await assertFails(setDoc(ref, { ...valid(), nonce: Bytes.fromUint8Array(new Uint8Array(11)) }));
  await assertFails(setDoc(ref, valid(false, 2)));
  await assertSucceeds(setDoc(ref, valid()));
  await assertSucceeds(getDocs(collection(db, "users/snippet-alice/commandSnippets")));
  await assertFails(setDoc(ref, valid(false, 1)));
  await assertFails(setDoc(ref, valid(false, 3)));
  await assertFails(setDoc(ref, { ...valid(false, 2), recordType: "host" }));
  await assertSucceeds(setDoc(ref, valid(false, 2)));
  await assertSucceeds(setDoc(ref, valid(true, 3)));
  await assertFails(setDoc(ref, valid(false, 4)));
  await assertFails(deleteDoc(ref));
  const other = testEnvironment.authenticatedContext("snippet-bob").firestore();
  await assertFails(getDoc(doc(other, `users/snippet-alice/commandSnippets/${id}`)));
  await assertFails(setDoc(doc(other, `users/snippet-alice/commandSnippets/${id}`), valid(true, 4)));
  const anon = testEnvironment.unauthenticatedContext().firestore();
  await assertFails(getDocs(collection(anon, "users/snippet-alice/commandSnippets")));
  await assertFails(setDoc(doc(anon, `users/snippet-alice/commandSnippets/${id}`), valid()));
  await assertFails(setDoc(doc(db, `users/snippet-alice/vault/${id}`), valid()));
  await assertSucceeds(setDoc(doc(db, `users/snippet-alice/vault/${id}`), validMetadataRecord("host")));
});
