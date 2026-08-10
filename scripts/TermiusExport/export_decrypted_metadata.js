#!/usr/bin/env node

// Run this script with Termius's Electron runtime:
// ELECTRON_RUN_AS_NODE=1 /Applications/Termius.app/Contents/MacOS/Termius \
//   Scripts/TermiusExport/export_decrypted_metadata.js input.json output-directory
//
// The input must already contain host metadata only. This script deliberately
// has no code for password or private-key fields.

const fs = require("node:fs");
const path = require("node:path");

const [, , inputArgument, outputArgument] = process.argv;
if (!inputArgument || !outputArgument) {
  throw new Error("Expected an encrypted metadata input file and output directory.");
}

const resources = "/Applications/Termius.app/Contents/Resources/app.asar.unpacked/node_modules/@termius";
const keytar = require(path.join(resources, "keytar/mac-arm64/keytar.node"));
const libtermius = require(path.join(resources, "libtermius"));

const inputPath = path.resolve(inputArgument);
const outputDirectory = path.resolve(outputArgument);
const source = JSON.parse(fs.readFileSync(inputPath, "utf8"));

function csvCell(value) {
  const text = value == null ? "" : String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function platformFromTermius(osName) {
  const value = String(osName || "").toLowerCase();
  const mappings = [
    ["ubuntu", "ubuntu"],
    ["debian", "debian"],
    ["alma", "almaLinux"],
    ["rocky", "rockyLinux"],
    ["centos", "centOS"],
    ["redhat", "redHat"],
    ["rhel", "redHat"],
    ["fedora", "fedora"],
    ["amazon", "amazonLinux"],
    ["alpine", "alpine"],
    ["suse", "openSUSE"],
    ["arch", "archLinux"],
    ["mac", "macOS"],
    ["freebsd", "freeBSD"],
    ["cisco", "cisco"],
    ["junos", "juniper"],
    ["juniper", "juniper"],
    ["arista", "arista"],
    ["openwrt", "openWrt"],
  ];
  return mappings.find(([term]) => value.includes(term))?.[1] || null;
}

function writePrivateFile(filePath, data) {
  fs.writeFileSync(filePath, data, { encoding: "utf8", mode: 0o600 });
  fs.chmodSync(filePath, 0o600);
}

async function run() {
  const localKey = await keytar.getPassword("Termius", "localKey");
  if (!localKey) {
    throw new Error("Termius local encryption key is unavailable in macOS Keychain.");
  }

  libtermius.crypto.init();
  const cryptor = libtermius.crypto.systems.FromEncryptionKey(
    Buffer.from(localKey, "base64"),
  );

  const decrypt = (ciphertext) => {
    if (!ciphertext) return "";
    const result = cryptor.decrypt(Buffer.from(ciphertext, "base64"));
    if (!result) throw new Error("Termius metadata decryption failed.");
    return result.toString("utf8").trim();
  };

  const groups = source.groups.map((group) => ({
    sourceID: group.source_id,
    name: decrypt(group.name),
    parentSourceID: group.parent_source_id ?? null,
    updatedAt: group.updated_at ?? null,
  }));
  const groupsByID = new Map(groups.map((group) => [group.sourceID, group]));

  const groupPath = (sourceID, visited = new Set()) => {
    if (sourceID == null || visited.has(sourceID)) return "";
    const group = groupsByID.get(sourceID);
    if (!group) return "";
    visited.add(sourceID);
    const parent = groupPath(group.parentSourceID, visited);
    return parent ? `${parent} / ${group.name}` : group.name;
  };

  const hosts = source.hosts.map((host) => ({
    sourceID: host.source_id,
    name: decrypt(host.name),
    hostname: decrypt(host.hostname),
    port: Number(host.port) || 22,
    username: decrypt(host.username),
    group: groupPath(host.group_source_id),
    detectedPlatform: platformFromTermius(host.os_name),
    termiusOSName: host.os_name || "",
    hasTermiusPrivateKey: Boolean(host.has_termius_private_key),
    updatedAt: host.updated_at ?? null,
  }));

  const duplicateKeys = new Map();
  for (const host of hosts) {
    const key = [host.hostname.toLowerCase(), host.port, host.username.toLowerCase()].join("|");
    duplicateKeys.set(key, [...(duplicateKeys.get(key) || []), host.sourceID]);
  }
  const duplicates = [...duplicateKeys.entries()]
    .filter(([, sourceIDs]) => sourceIDs.length > 1)
    .map(([connectionKey, sourceIDs]) => ({ connectionKey, sourceIDs }));

  const exportedAt = new Date().toISOString();
  const document = {
    format: "myterm-termius-host-export-v1",
    exportedAt,
    source: "Termius 9.38.2 local vault",
    security: {
      containsPasswords: false,
      containsPrivateKeys: false,
      note: "Host metadata only. Passwords, passphrases, private keys, tokens, and encrypted content are excluded.",
    },
    summary: {
      groupCount: groups.length,
      hostCount: hosts.length,
      hostsWithoutUsername: hosts.filter((host) => !host.username).length,
      hostsReferencingTermiusPrivateKeys: hosts.filter((host) => host.hasTermiusPrivateKey).length,
      duplicateConnectionCount: duplicates.length,
    },
    groups,
    hosts,
    duplicates,
  };

  const csvHeaders = [
    "name",
    "hostname",
    "port",
    "username",
    "group",
    "detectedPlatform",
    "termiusOSName",
    "hasTermiusPrivateKey",
    "sourceID",
    "updatedAt",
  ];
  const csv = [
    csvHeaders.join(","),
    ...hosts.map((host) => csvHeaders.map((header) => csvCell(host[header])).join(",")),
  ].join("\n") + "\n";

  fs.mkdirSync(outputDirectory, { recursive: true, mode: 0o700 });
  const jsonPath = path.join(outputDirectory, "termius-hosts.json");
  const csvPath = path.join(outputDirectory, "termius-hosts.csv");
  writePrivateFile(jsonPath, JSON.stringify(document, null, 2) + "\n");
  writePrivateFile(csvPath, csv);

  console.log(
    JSON.stringify({
      jsonPath,
      csvPath,
      groupCount: groups.length,
      hostCount: hosts.length,
      duplicateConnectionCount: duplicates.length,
    }),
  );
}

run().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
