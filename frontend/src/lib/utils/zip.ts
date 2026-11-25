/**
 * Minimal ZIP writer (store method, no compression) with CRC32.
 *
 * Just enough to wrap a single image + metadata.json into an archive the
 * gallery `/api/import` endpoint accepts — used to import a lone uploaded
 * reference image into the gallery (and hence into a collection). No
 * dependency: the deflate tables and CRC32 are generated on the fly.
 */

const CRC_TABLE: Uint32Array = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i += 1) {
    c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function dosDateTime(date: Date): { time: number; dateVal: number } {
  const time =
    ((date.getHours() & 0x1f) << 11) |
    ((date.getMinutes() & 0x3f) << 5) |
    ((date.getSeconds() >> 1) & 0x1f);
  const dateVal =
    ((((date.getFullYear() - 1980) & 0x7f) << 9) |
      ((date.getMonth() + 1) << 5) |
      date.getDate()) &
    0xffff;
  return { time, dateVal };
}

function encodeName(name: string): Uint8Array {
  return new TextEncoder().encode(name);
}

interface ZipEntry {
  name: string;
  data: Uint8Array;
}

/** Build a ZIP (all members stored) from a set of named byte payloads. */
export function buildZip(entries: ZipEntry[]): Uint8Array {
  const nameBytesOf = entries.map((e) => encodeName(e.name));
  const crcs = entries.map((e) => crc32(e.data));
  const sizes = entries.map((e) => e.data.length);
  const { time, dateVal } = dosDateTime(new Date());

  // layout: [local headers + data] [central headers] [EOCD]
  const localTotal = entries.reduce((acc, _e, i) => acc + 30 + nameBytesOf[i].length + sizes[i], 0);
  const centralTotal = entries.reduce((acc, _e, i) => acc + 46 + nameBytesOf[i].length, 0);
  const total = localTotal + centralTotal + 22;
  const out = new Uint8Array(total);
  const dv = new DataView(out.buffer);

  let off = 0;
  const localOffsets: number[] = [];
  for (let i = 0; i < entries.length; i += 1) {
    const nameBytes = nameBytesOf[i];
    const size = sizes[i];
    localOffsets[i] = off;
    // local file header
    dv.setUint32(off, 0x04034b50, true);
    dv.setUint16(off + 4, 20, true);
    dv.setUint16(off + 6, 0, true);
    dv.setUint16(off + 8, 0, true);
    dv.setUint16(off + 10, time, true);
    dv.setUint16(off + 12, dateVal, true);
    dv.setUint32(off + 14, crcs[i], true);
    dv.setUint32(off + 18, size, true);
    dv.setUint32(off + 22, size, true);
    dv.setUint16(off + 26, nameBytes.length, true);
    dv.setUint16(off + 28, 0, true);
    out.set(nameBytes, off + 30);
    out.set(entries[i].data, off + 30 + nameBytes.length);
    off += 30 + nameBytes.length + size;
  }

  // central directory (each entry's local offset is known from above)
  const centralStart = off;
  let cOff = centralStart;
  for (let i = 0; i < entries.length; i += 1) {
    const nameBytes = nameBytesOf[i];
    const size = sizes[i];
    dv.setUint32(cOff, 0x02014b50, true);
    dv.setUint16(cOff + 4, 20, true);
    dv.setUint16(cOff + 6, 20, true);
    dv.setUint16(cOff + 8, 0, true);
    dv.setUint16(cOff + 10, 0, true);
    dv.setUint16(cOff + 12, time, true);
    dv.setUint16(cOff + 14, dateVal, true);
    dv.setUint32(cOff + 16, crcs[i], true);
    dv.setUint32(cOff + 20, size, true);
    dv.setUint32(cOff + 24, size, true);
    dv.setUint16(cOff + 28, nameBytes.length, true);
    dv.setUint16(cOff + 30, 0, true);
    dv.setUint16(cOff + 32, 0, true);
    dv.setUint16(cOff + 34, 0, true);
    dv.setUint16(cOff + 36, 0, true);
    dv.setUint32(cOff + 38, 0, true);
    dv.setUint32(cOff + 42, localOffsets[i], true); // local header offset
    out.set(nameBytes, cOff + 46);
    cOff += 46 + nameBytes.length;
  }

  // end of central directory
  const eocd = new DataView(out.buffer, centralStart + (cOff - centralStart));
  eocd.setUint32(0, 0x06054b50, true);
  eocd.setUint16(4, 0, true);
  eocd.setUint16(6, 0, true);
  eocd.setUint16(8, entries.length, true);
  eocd.setUint16(10, entries.length, true);
  eocd.setUint32(12, centralTotal, true);
  eocd.setUint32(16, localTotal, true);
  eocd.setUint16(20, 0, true);
  return out;
}

/**
 * Wrap a single image File into an importable archive whose entry id is
 * exactly `imageId` (the id we control), so we can add it to a collection
 * by that id immediately after import.
 */
export async function singleImageImportZip(file: File, imageId: string): Promise<Uint8Array> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const metadata = JSON.stringify({
    images: [
      {
        id: imageId,
        filename: file.name,
        prompt: file.name.replace(/\.[^.]+$/, ''),
        size: ''
      }
    ]
  });
  return buildZip([
    { name: file.name, data: bytes },
    { name: 'metadata.json', data: encodeName(metadata) }
  ]);
}
