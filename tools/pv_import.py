#!/usr/bin/env python3
"""Import a Google Takeout export of Google Photos into a PhotoVault vault.

  pv_import.py plan   --source gdrive:Takeout --state ~/pv-import
  pv_import.py run    --source gdrive:Takeout --dest hidrive:PhotoVault --state ~/pv-import [--limit N] [--yes] ...
  pv_import.py verify --dest hidrive:PhotoVault --state ~/pv-import

The importer is one more PhotoVault device: originals/<id>.enc, thumbs/<id>.enc and
journal/<deviceId>/<seq>-<uuid>.enc use the formats of PhotoVault/Crypto/BlobCrypto.swift and
PhotoVault/Engine/Journal.swift. Takeout ZIPs are read in place through `rclone cat --offset` range reads,
never downloaded. --source and --dest also accept local directories (paths without ':').
Requires Python 3.10+, `pip install -r tools/requirements.txt`, rclone for remotes; ffmpeg/ffprobe optional.
"""
import argparse
import base64
import datetime as dt
import errno
import fcntl
import getpass
import hashlib
import hmac
import io
import json
import logging
import math
import os
import re
import secrets
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zipfile

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

try:
    from PIL import Image, ImageDraw, ImageFont, ImageOps
    Image.MAX_IMAGE_PIXELS = None  # the user's own photos: large panoramas are legitimate
except ImportError:  # plan and verify work without Pillow
    Image = None
try:
    import pillow_heif
    pillow_heif.register_heif_opener()
except ImportError:
    pillow_heif = None

CHUNK = 65536                      # BlobCrypto.chunkSize
HKDF_INFO = b"photovault-blob-v1"
JOURNAL_MAX = 500                  # entries per journal file
THUMB_PX, THUMB_QUALITY = 512, 70  # PhotoKitExport.generateThumbnail + jpegData(compressionQuality: 0.7)
LIVE_MAX_SECONDS = 3.5
DISCARD_MAX = 32 << 20             # forward seeks shorter than this are read and discarded
RETRY_WINDOW = 30 * 60             # a dead source stream is reopened for this long before giving up
UPLOAD_EVERY = 15
BIG_PHOTO = 256 << 20              # larger photos are spooled to disk like videos
SIDECAR_MAX = 4 << 20

PHOTO_MIME = {
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "heic": "image/heic", "heif": "image/heif", "png": "image/png",
    "gif": "image/gif", "webp": "image/webp", "tif": "image/tiff", "tiff": "image/tiff",
    "dng": "image/x-adobe-dng", "cr2": "image/x-canon-cr2", "nef": "image/x-nikon-nef", "arw": "image/x-sony-arw",
}
VIDEO_MIME = {
    "mp4": "video/mp4", "mov": "video/quicktime", "m4v": "video/x-m4v", "3gp": "video/3gpp", "avi": "video/avi",
    "mkv": "video/x-matroska", "webm": "video/webm", "mts": "video/mp2t",
}
MIME = {**PHOTO_MIME, **VIDEO_MIME}
RAW_EXTS = {"dng", "cr2", "nef", "arw"}
LIVE_VIDEO_EXTS = {"mp4", "mov"}
TRASH_FOLDERS = {"trash", "bin", "papperskorg", "papperskorgen", "papierkorb"}
SUPPLEMENTAL = "supplemental-metadata"
N_RE = re.compile(r"\(\d+\)$")
EDITED_RE = re.compile(r"-(edited|bearbeitet|modifié|editado|modificato|bewerkt|redigerad)$", re.IGNORECASE)
YEAR_RE = re.compile(r"(?<!\d)(\d{4})$")
JOURNAL_NAME_RE = re.compile(r"^\d{6}-([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\.enc$")
MEDIA_SQL = "kind IN ('photo', 'video')"
EPOCH = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)

log = logging.getLogger("pv_import")


class Fatal(Exception):
    pass


class SourceError(Exception):
    pass


def die(message):
    raise Fatal(message)


def say(message):
    print(message, flush=True)
    log.info(message)


def gb(n):
    return f"{n / 1e9:.2f} GB"


def hms(seconds):
    seconds = int(seconds)
    return f"{seconds // 3600}h{seconds % 3600 // 60:02d}m" if seconds >= 3600 else f"{seconds // 60}m{seconds % 60:02d}s"


def is_remote(path):
    return ":" in path and not path.startswith(("/", ".", "~"))


def rjoin(base, *parts):
    for part in parts:
        base = base + part if base.endswith((":", "/")) else base + "/" + part
    return base


def split_ext(name):
    stem, dot, ext = name.rpartition(".")
    return (stem, "." + ext) if dot and stem else (name, "")


def ext_of(name):
    return split_ext(name)[1][1:].lower()


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def valid_ts(ts):
    return ts is not None and ts != 0 and -2208988800 <= ts < 7258118400  # 1900 .. 2200


def iso(ts):
    # JSONEncoder.dateEncodingStrategy = .iso8601: whole seconds, UTC, "Z" (fractions would not decode).
    return (EPOCH + dt.timedelta(seconds=int(ts))).strftime("%Y-%m-%dT%H:%M:%SZ")


def confirm(prompt):
    try:
        return input(prompt).strip().lower() in ("y", "yes")
    except EOFError:
        return False


# ---------------------------------------------------------------- recovery string and blob format


def master_key_from_recovery(recovery):
    # Decoded exactly like tools/pv_decrypt.py and Base32.swift: RFC 4648 base32, no padding, 52 chars -> 32 bytes.
    b32 = "".join(recovery.split()).replace("-", "").upper()
    if len(b32) != 52 or not re.fullmatch(r"[A-Z2-7]+", b32):
        die("the recovery string must be 52 base32 characters")
    master = base64.b32decode(b32 + "=" * (-len(b32) % 8))
    if len(master) != 32:
        die("recovery string does not decode to 32 bytes")
    return master


def read_recovery(path):
    """(master key, whether it was typed at a prompt); never taken from the command line."""
    if path:
        if os.stat(path).st_mode & 0o077:
            die(f"{path} must be readable by its owner only (chmod 600)")
        with open(path, encoding="utf-8") as f:
            return master_key_from_recovery(f.read()), False
    if os.environ.get("PV_RECOVERY"):
        return master_key_from_recovery(os.environ["PV_RECOVERY"]), False
    return master_key_from_recovery(getpass.getpass("Recovery string: ")), True


def blob_aead(master, blob_id):
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=uuid.UUID(blob_id).bytes, info=HKDF_INFO).derive(master)
    return AESGCM(key)


def seal_blob(src, length, dst, aead, avoid_nonce=None):
    """Write the PVLT container of BlobCrypto.encryptFile for `length` plaintext bytes (bytes or a binary file).

    Header: "PVLT" | 1 | 3 zero bytes | chunkSize u32 LE | plaintextLength u64 LE | 4-byte nonce base.
    Chunk i: AES-256-GCM, nonce = nonceBase || i u64 LE, AAD = header || i u64 LE, output ciphertext || tag."""
    nonce_base = secrets.token_bytes(4)
    while nonce_base == avoid_nonce:  # original and thumb share one key: keep their nonces apart
        nonce_base = secrets.token_bytes(4)
    header = b"PVLT" + bytes((1, 0, 0, 0)) + struct.pack("<IQ", CHUNK, length) + nonce_base
    view = memoryview(src) if isinstance(src, (bytes, bytearray)) else None
    with open(dst, "wb") as out:
        out.write(header)
        index = offset = 0
        while offset < length:
            want = min(CHUNK, length - offset)
            chunk = bytes(view[offset:offset + want]) if view is not None else src.read(want)
            if len(chunk) != want:
                raise IOError("plaintext shorter than expected")
            counter = struct.pack("<Q", index)
            out.write(aead.encrypt(nonce_base + counter, chunk, header + counter))
            index += 1
            offset += want
        out.flush()
        os.fsync(out.fileno())
    return nonce_base


def open_blob(data, master, blob_id):
    """Decrypt a whole PVLT blob held in memory (used to check the recovery string against the vault)."""
    header = data[:24]
    if len(header) != 24 or header[:4] != b"PVLT" or header[4] != 1:
        raise ValueError("not a PhotoVault blob")
    chunk_size, length = struct.unpack("<IQ", header[8:20])
    if chunk_size == 0:
        raise ValueError("bad chunk size")
    aead, out, pos, index = blob_aead(master, blob_id), bytearray(), 24, 0
    while len(out) < length:
        want = min(chunk_size, length - len(out))
        sealed = data[pos:pos + want + 16]
        if len(sealed) != want + 16:
            raise ValueError("truncated blob")
        counter = struct.pack("<Q", index)
        out += aead.decrypt(header[20:24] + counter, sealed, header + counter)
        pos += want + 16
        index += 1
    return bytes(out)


# ---------------------------------------------------------------- archive access


class RcloneRangeFile:
    """Seekable read-only file over `rclone cat --offset N remote:path`, handed to zipfile.ZipFile.

    One long-lived rclone process streams sequentially. seek() only moves the target position; read()
    continues the stream when it is there, reads and discards forward gaps below 32 MiB, and otherwise
    reopens the stream at the target. A stream that dies or ends early is reopened at the current position
    with exponential backoff for up to 30 minutes."""

    def __init__(self, remote, size):
        self.remote, self.size = remote, size
        self.pos = self.stream_pos = self.bytes_read = 0
        self.proc = self.err = None

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        target = (0, self.pos, self.size)[whence] + offset
        if target < 0:
            raise OSError("seek before the start of the file")
        self.pos = target
        return target

    def read(self, n=-1):
        if n is None or n < 0 or n > self.size - self.pos:
            n = max(0, self.size - self.pos)
        out, failing_since, delay = bytearray(), None, 1.0
        while len(out) < n:
            data = b""
            try:
                self._align()
                data = self.proc.stdout.read(n - len(out))
            except OSError as exc:
                log.debug("rclone cat: %s", exc)
            if data:
                out += data
                self.pos += len(data)
                self.stream_pos += len(data)
                self.bytes_read += len(data)
                failing_since, delay = None, 1.0
                continue
            reason = self._stop()
            if re.search(r"not found|didn't find section", reason, re.IGNORECASE):
                raise SourceError(f"{self.remote}: {reason}")
            now = time.monotonic()
            failing_since = failing_since or now
            if now - failing_since > RETRY_WINDOW:
                raise SourceError(f"{self.remote}: no data at offset {self.pos} for 30 minutes: {reason}")
            log.warning("stream of %s ended at %d (%s); reopening in %.0f s", self.remote, self.pos, reason or "EOF", delay)
            time.sleep(delay)
            delay = min(delay * 2, 60)
        return bytes(out)

    def _align(self):
        if self.proc is not None:
            gap = self.pos - self.stream_pos
            while 0 < gap < DISCARD_MAX:
                chunk = self.proc.stdout.read(min(gap, 1 << 20))
                if not chunk:
                    break
                gap -= len(chunk)
                self.stream_pos += len(chunk)
                self.bytes_read += len(chunk)
            if gap == 0:
                return
            self._stop()
        self.err = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(["rclone", "cat", "--offset", str(self.pos), self.remote],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=self.err,
                                     bufsize=1 << 20, start_new_session=True)
        self.stream_pos = self.pos
        log.debug("rclone cat --offset %d %s", self.pos, self.remote)

    def _stop(self):
        if self.proc is None:
            return ""
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.stdout.close()
        self.proc.wait()
        self.err.seek(0)
        reason = self.err.read().decode("utf-8", "replace").strip()[-400:]
        self.err.close()
        self.proc = self.err = None
        return reason

    def close(self):
        self._stop()


class LocalFile:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.bytes_read = 0

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.f.tell()

    def seek(self, offset, whence=0):
        return self.f.seek(offset, whence)

    def read(self, n=-1):
        data = self.f.read(n)
        self.bytes_read += len(data)
        return data

    def close(self):
        self.f.close()


def rclone(*args, check=True):
    log.debug("$ rclone %s", " ".join(args))
    p = subprocess.run(["rclone", *args], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                       start_new_session=True)
    if check and p.returncode:
        die(f"rclone {args[0]} failed ({p.returncode}): {p.stderr.strip()[-400:]}")
    return p


def missing_dir(p):
    return p.returncode == 3 or "not found" in p.stderr.lower()


def need_rclone(*paths):
    if any(p and is_remote(p) for p in paths) and not shutil.which("rclone"):
        die("rclone not found (install it with: curl https://rclone.org/install.sh | sudo bash)")


def list_archives(source):
    if is_remote(source):
        p = rclone("lsjson", "--files-only", "--no-mimetype", "--no-modtime", source)
        items = [(o["Name"], int(o["Size"])) for o in json.loads(p.stdout or "[]")]
    elif os.path.isdir(source):
        items = [(n, os.path.getsize(os.path.join(source, n))) for n in os.listdir(source)
                 if os.path.isfile(os.path.join(source, n))]
    else:
        die(f"{source} is not a directory")
    archives = sorted(item for item in items if item[0].lower().endswith(".zip"))
    if not archives:
        die(f"no .zip archives in {source}")
    return archives


def open_archive(source, name, size):
    return RcloneRangeFile(rjoin(source, name), size) if is_remote(source) else LocalFile(os.path.join(source, name))


def dest_names(dest, sub):
    """Names of the files directly in dest/sub; empty when the directory does not exist."""
    if is_remote(dest):
        p = rclone("lsf", "--files-only", rjoin(dest, sub), check=False)
        if p.returncode == 0:
            return {line for line in p.stdout.splitlines() if line}
        if missing_dir(p):
            return set()
        die(f"rclone lsf {rjoin(dest, sub)} failed: {p.stderr.strip()[-400:]}")
    path = os.path.join(dest, sub)
    return {n for n in os.listdir(path) if os.path.isfile(os.path.join(path, n))} if os.path.isdir(path) else set()


def vault_journal_files(dest):
    """[(size, 'deviceId/name')] of every journal file in the vault."""
    if is_remote(dest):
        p = rclone("lsjson", "-R", "--files-only", "--no-mimetype", "--no-modtime", rjoin(dest, "journal"), check=False)
        if p.returncode:
            if missing_dir(p):
                return []
            die(f"rclone lsjson {rjoin(dest, 'journal')} failed: {p.stderr.strip()[-400:]}")
        return [(int(o["Size"]), o["Path"]) for o in json.loads(p.stdout or "[]")]
    root, found = os.path.join(dest, "journal"), []
    for dirpath, _, names in os.walk(root):
        for name in names:
            path = os.path.join(dirpath, name)
            found.append((os.path.getsize(path), os.path.relpath(path, root)))
    return found


def read_dest(dest, rel):
    if is_remote(dest):
        p = subprocess.run(["rclone", "cat", rjoin(dest, rel)], stdin=subprocess.DEVNULL, capture_output=True,
                           start_new_session=True)
        if p.returncode:
            die(f"rclone cat {rjoin(dest, rel)} failed: {p.stderr.decode('utf-8', 'replace').strip()[-400:]}")
        return p.stdout
    with open(os.path.join(dest, rel), "rb") as f:
        return f.read()


# ---------------------------------------------------------------- Takeout naming rules


def media_keys(base):
    """Sidecar lookup keys of a media name: the name itself, then a trailing '(n)' moved behind the extension
    (IMG_1(1).HEIC -> IMG_1.HEIC(1)), then the same without an '-edited' suffix (edits share the sidecar)."""
    stem, ext = split_ext(base)
    m = N_RE.search(stem)
    n, core = (m.group(0), stem[:m.start()]) if m else ("", stem)
    keys = [base, core + ext + n]
    edited = EDITED_RE.search(core)
    if edited:
        original = core[:edited.start()]
        m = N_RE.search(original)
        if m and not n:
            n, original = m.group(0), original[:m.start()]
        keys.append(original + ext + n)
    return list(dict.fromkeys(keys))


def edited_suffix(base):
    edited = EDITED_RE.search(N_RE.sub("", split_ext(base)[0]))
    return edited.group(0) if edited else ""


def sidecar_parts(base):
    """'IMG_1.JPG.supplemental-metad(1).json' -> ('IMG_1.JPG', '(1)'): media part and duplicate counter.
    Google truncates long sidecar names, cutting '.supplemental-metadata' and even the media name."""
    s, n = base[:-5], ""
    m = N_RE.search(s)
    if m:
        n, s = m.group(0), s[:m.start()]
    stem, dot, tail = s.rpartition(".")
    if dot and stem and (not tail or SUPPLEMENTAL.startswith(tail.lower())):
        s = stem
    return s, n


def is_sidecar(base):
    # Album metadata.json, print-subscriptions.json etc. carry no media extension.
    return base.lower().endswith(".json") and ("." in sidecar_parts(base)[0] or len(base) >= 40)


def pair_folder(media, sidecars):
    """media, sidecars: [(id, name)] of one folder -> {media id: sidecar id}."""
    exact, folded, parts = {}, {}, []
    for sid, base in sidecars:
        part, n = sidecar_parts(base)
        exact.setdefault(part + n, sid)
        folded.setdefault((part + n).lower(), sid)
        parts.append((part, n, sid))
    pairs, claimed = {}, set()
    for mid, base in media:
        for key in media_keys(base):
            sid = exact.get(key) or folded.get(key.lower())
            if sid:
                pairs[mid] = sid
                claimed.add(sid)
                break
    free = [(part, n, sid) for part, n, sid in parts if part and sid not in claimed]
    for mid, base in media:  # truncated sidecar names: the longest unclaimed media part that is a prefix
        if mid in pairs or not free:
            continue
        best = None
        for key in media_keys(base):
            m = N_RE.search(key)
            kn, kpart = (m.group(0), key[:m.start()]) if m else ("", key)
            for part, n, sid in free:
                if n == kn and kpart.startswith(part) and (best is None or len(part) > best[0]):
                    best = (len(part), sid)
        if best:
            pairs[mid] = best[1]
    return pairs


def classify(folders, skip_names):
    """Folder -> primary (year folders) | skip (trash) | secondary (albums, archive, everything else)."""
    skip = TRASH_FOLDERS | set(skip_names)
    cls, years = {}, {}
    for folder in folders:
        name = folder.rsplit("/", 1)[-1].strip()
        m = YEAR_RE.search(name)
        if name.lower() in skip:
            cls[folder] = "skip"
        elif m and 1800 <= int(m.group(1)) <= 2199:
            years.setdefault(name[:m.start()].strip().lower(), []).append(folder)
        else:
            cls[folder] = "secondary"
    # Year folders share one localized prefix ("Photos from", "Foton från"); an album that merely ends in a
    # year ("Italy 2019") does not, and must stay secondary or its copies would be imported twice.
    if years:
        main = max(years, key=lambda p: (bool(re.search("photo|foto", p)), len(years[p])))
        for prefix, group in years.items():
            for folder in group:
                cls[folder] = "primary" if prefix == main else "secondary"
    return cls


def folder_year(folder):
    m = YEAR_RE.search(folder.rsplit("/", 1)[-1].strip())
    return int(m.group(1)) if m and 1800 <= int(m.group(1)) <= 2199 else None


def journal_filename(base, title):
    """Sidecar title (the original name), else the ZIP name. The extension always matches the stored bytes (the
    app caches originals under it) and edited copies keep their '-edited' marker."""
    name = re.sub(r"[/\x00-\x1f]", "_", (title or "").strip()) or base
    stem, ext = split_ext(name)
    zext = split_ext(base)[1]
    norm = {"jpeg": "jpg", "tiff": "tif", "heif": "heic"}
    if norm.get(ext[1:].lower(), ext[1:].lower()) != norm.get(zext[1:].lower(), zext[1:].lower()):
        stem, ext = (stem if ext[1:].lower() in MIME else name), zext
    marker = edited_suffix(base)
    if marker and not EDITED_RE.search(N_RE.sub("", stem)):
        stem += marker
    return stem + ext


def parse_sidecar(raw):
    j = json.loads(raw.decode("utf-8-sig"))
    if not isinstance(j, dict):
        raise ValueError("not a JSON object")
    out = {}
    taken = j.get("photoTakenTime")  # capture time; creationTime is the upload time
    try:
        ts = int(taken.get("timestamp")) if isinstance(taken, dict) else None
        if valid_ts(ts):
            out["taken"] = ts
    except (TypeError, ValueError):
        pass
    if isinstance(j.get("title"), str) and j["title"].strip():
        out["title"] = j["title"].strip()
    if isinstance(j.get("description"), str) and j["description"].strip():
        out["description"] = j["description"]
    geo = j.get("geoData") if isinstance(j.get("geoData"), dict) else {}
    lat, lon = geo.get("latitude"), geo.get("longitude")
    if isinstance(lat, (int, float)) and isinstance(lon, (int, float)) and (lat, lon) != (0, 0):
        out["lat"], out["lon"] = float(lat), float(lon)
    if isinstance(j.get("favorited"), bool):
        out["favorited"] = j["favorited"]
    return out


def capture_time(row, info, sc):
    """Capture time and its source: sidecar photoTakenTime > EXIF > video container > folder year > ZIP mtime."""
    if sc.get("taken") is not None:
        return sc["taken"], "sidecar"
    if info.get("exif") is not None:
        return info["exif"], "exif"
    if info.get("created") is not None:
        return info["created"], info.get("created_src") or "ffprobe"
    year = folder_year(row["folder"])
    if year:
        return dt.datetime(year, 1, 1, 12).astimezone().timestamp(), "folder"
    return row["mtime"] or time.time(), "zip"


# ---------------------------------------------------------------- media facts and thumbnails


def exif_time(raw, offset):
    """EXIF DateTimeOriginal (+ OffsetTimeOriginal; without one, the laptop's local time) as a Unix time."""
    if isinstance(raw, bytes):
        raw = raw.decode("ascii", "replace")
    m = re.match(r"\s*(\d{4})[:-](\d\d)[:-](\d\d)[ T](\d\d):(\d\d):(\d\d)", raw) if isinstance(raw, str) else None
    if not m:
        return None
    try:
        when = dt.datetime(*map(int, m.groups()))
    except ValueError:
        return None
    if isinstance(offset, bytes):
        offset = offset.decode("ascii", "replace")
    o = re.match(r"\s*([+-])(\d\d):(\d\d)", offset) if isinstance(offset, str) else None
    if o:
        delta = dt.timedelta(hours=int(o.group(2)), minutes=int(o.group(3)))
        when = when.replace(tzinfo=dt.timezone(delta if o.group(1) == "+" else -delta))
    else:
        when = when.astimezone()
    ts = when.timestamp()
    return ts if valid_ts(ts) else None


def iso_time(text):
    m = re.match(r"\s*(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)", text or "")
    if not m:
        return None
    try:
        ts = dt.datetime(*map(int, m.groups()), tzinfo=dt.timezone.utc).timestamp()
    except ValueError:
        return None
    return ts if valid_ts(ts) else None


def make_thumb(im, orientation=None):
    """512 px JPEG at quality 70 with the orientation applied, like the app's thumbnails."""
    icc = im.info.get("icc_profile")
    if im.format == "JPEG":
        im.draft("RGB", (THUMB_PX, THUMB_PX))
    if orientation is None:
        im = ImageOps.exif_transpose(im)
    else:
        im.load()
        t = Image.Transpose
        method = {2: t.FLIP_LEFT_RIGHT, 3: t.ROTATE_180, 4: t.FLIP_TOP_BOTTOM, 5: t.TRANSPOSE, 6: t.ROTATE_270,
                  7: t.TRANSVERSE, 8: t.ROTATE_90}.get(orientation)
        if method is not None:
            im = im.transpose(method)
    if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
        rgba = im.convert("RGBA")
        im = Image.new("RGB", rgba.size, (255, 255, 255))
        im.paste(rgba, mask=rgba.getchannel("A"))
    elif im.mode != "RGB":
        im = im.convert("RGB")
    im.thumbnail((THUMB_PX, THUMB_PX), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    im.save(out, "JPEG", quality=THUMB_QUALITY, icc_profile=icc)
    return out.getvalue()


def raw_preview_thumb(data, orientation):
    """Thumbnail from the largest JPEG preview embedded in a RAW file."""
    best, start = None, 0
    for _ in range(12):
        i = data.find(b"\xff\xd8\xff", start)
        if i < 0:
            break
        start = i + 3
        try:
            im = Image.open(io.BytesIO(data[i:]))
        except Exception:
            continue
        if im.format == "JPEG" and (best is None or im.width * im.height > best.width * best.height):
            best = im
    if best is None:
        return None
    try:
        return make_thumb(best, None if best.getexif().get(0x0112) else orientation)
    except Exception:
        return None


def placeholder_thumb(ext):
    im = Image.new("RGB", (THUMB_PX, THUMB_PX), (128, 128, 128))
    draw, label = ImageDraw.Draw(im), (ext or "?").upper()
    try:
        font = ImageFont.load_default(size=120)
    except Exception:  # Pillow < 10.1: fixed-size bitmap font
        font = ImageFont.load_default()
    left, top, right, bottom = draw.textbbox((0, 0), label, font=font)
    draw.text(((THUMB_PX - right - left) / 2, (THUMB_PX - bottom - top) / 2), label, fill=(230, 230, 230), font=font)
    out = io.BytesIO()
    im.save(out, "JPEG", quality=THUMB_QUALITY)
    return out.getvalue()


def photo_info(src, ext):
    """(width, height, EXIF capture time, thumbnail or None) of a photo in memory (bytes) or in a file."""
    width = height = 0
    taken = thumb = im = None
    orientation = 1
    try:
        im = Image.open(io.BytesIO(src) if isinstance(src, bytes) else src)
        exif = im.getexif()
        orientation = exif.get(0x0112, 1)
        sub = exif.get_ifd(0x8769)
        taken = exif_time(sub.get(0x9003), sub.get(0x9011))
        # A RAW file opens as its TIFF container's first image, usually a small preview: trust only EXIF sizes.
        w, h = (sub.get(0xA002, 0), sub.get(0xA003, 0)) if ext in RAW_EXTS else im.size
        w, h = int(w or 0), int(h or 0)
        width, height = (h, w) if orientation in (5, 6, 7, 8) else (w, h)
    except Exception as exc:
        log.info("Pillow cannot read this .%s: %s", ext, exc)
    if ext in RAW_EXTS and isinstance(src, bytes):
        thumb = raw_preview_thumb(src, orientation)
    if thumb is None and im is not None:
        try:
            thumb = make_thumb(im)
        except Exception as exc:
            log.info("no thumbnail from Pillow: %s", exc)
    return width, height, taken, thumb


def _boxes(f, start, end):
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        size, kind = struct.unpack(">I4s", f.read(8))
        head = 8
        if size == 1:
            size, head = struct.unpack(">Q", f.read(8))[0], 16
        elif size == 0:
            size = end - pos
        if size < head:
            return
        yield kind, pos + head, min(pos + size, end)
        pos += size


def _box(f, start, end, kind):
    return next(((s, e) for k, s, e in _boxes(f, start, end) if k == kind), None)


def bmff_info(path):
    """Duration, display size and creation time from an MP4/MOV header (the fallback without ffprobe)."""
    try:
        with open(path, "rb") as f:
            moov = _box(f, 0, os.fstat(f.fileno()).st_size, b"moov")
            if not moov:
                return None
            out = {}
            mvhd = _box(f, *moov, b"mvhd")
            if mvhd:
                f.seek(mvhd[0])
                version = f.read(4)[0]
                created, _, scale, duration = struct.unpack(">QQIQ" if version == 1 else ">IIII",
                                                            f.read(28 if version == 1 else 16))
                if scale:
                    out["duration"] = duration / scale
                if created:
                    out["created"] = created - 2082844800  # seconds since 1904
            for kind, start, end in _boxes(f, *moov):
                tkhd = _box(f, start, end, b"tkhd") if kind == b"trak" else None
                if not tkhd:
                    continue
                f.seek(tkhd[0])
                version = f.read(1)[0]
                f.seek(tkhd[0] + 4 + (32 if version == 1 else 20) + 16)
                matrix = struct.unpack(">9i", f.read(36))
                width, height = (v >> 16 for v in struct.unpack(">II", f.read(8)))
                if width and height:
                    angle = round(math.degrees(math.atan2(matrix[1], matrix[0]))) % 360
                    out["width"], out["height"] = (height, width) if angle in (90, 270) else (width, height)
                    break
            return out
    except (OSError, struct.error, IndexError, StopIteration):
        return None


def video_info(path, ffprobe):
    info = {"duration": None, "width": 0, "height": 0, "created": None, "created_src": None}
    if ffprobe:
        try:
            p = subprocess.run([ffprobe, "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=300, start_new_session=True)
            probe = json.loads(p.stdout or b"{}")
        except (OSError, subprocess.SubprocessError, ValueError) as exc:
            log.warning("ffprobe failed: %s", exc)
            probe = {}
        fmt = probe.get("format") or {}
        stream = next((s for s in probe.get("streams") or [] if s.get("codec_type") == "video"
                       and not (s.get("disposition") or {}).get("attached_pic")), None) or {}
        info["duration"] = number(fmt.get("duration")) or number(stream.get("duration"))
        width, height = int(stream.get("width") or 0), int(stream.get("height") or 0)
        rotation = (stream.get("tags") or {}).get("rotate")
        for side in stream.get("side_data_list") or []:
            rotation = side.get("rotation", rotation)
        if number(rotation) is not None and round(abs(number(rotation))) % 180 == 90:
            width, height = height, width
        info["width"], info["height"] = width, height
        created = iso_time((fmt.get("tags") or {}).get("creation_time") or (stream.get("tags") or {}).get("creation_time"))
        if created is not None:
            info["created"], info["created_src"] = created, "ffprobe"
    if info["duration"] is None or not info["width"] or info["created"] is None:
        box = bmff_info(path) or {}
        if info["duration"] is None:
            info["duration"] = box.get("duration")
        if not info["width"]:
            info["width"], info["height"] = box.get("width", 0), box.get("height", 0)
        if info["created"] is None and valid_ts(box.get("created")):
            info["created"], info["created_src"] = box["created"], "mp4-header"
    return info


def video_thumb(path, duration, ffmpeg):
    """Frame at 1 s (0 s for shorter clips), rotated as displayed, scaled to 512 px."""
    if not ffmpeg:
        return None
    for at in ((0,) if duration is not None and duration < 1 else (1, 0)):
        try:
            p = subprocess.run([ffmpeg, "-v", "error", "-nostdin", "-ss", str(at), "-i", path, "-frames:v", "1", "-vf",
                                f"scale='min({THUMB_PX},iw)':'min({THUMB_PX},ih)':force_original_aspect_ratio=decrease",
                                "-f", "image2pipe", "-vcodec", "png", "-pix_fmt", "rgb24", "-"],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=300, start_new_session=True)
            if p.returncode == 0 and p.stdout:
                return make_thumb(Image.open(io.BytesIO(p.stdout)))
        except Exception as exc:
            log.warning("ffmpeg thumbnail failed: %s", exc)
    return None


# ---------------------------------------------------------------- state


SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS archives (id INTEGER PRIMARY KEY, name TEXT UNIQUE, size INTEGER,
    done1 INTEGER NOT NULL DEFAULT 0, done2 INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY, archive INTEGER NOT NULL, path TEXT NOT NULL, folder TEXT NOT NULL, base TEXT NOT NULL,
    offset INTEGER NOT NULL, csize INTEGER, usize INTEGER, method INTEGER, mtime REAL,
    kind TEXT NOT NULL,                  -- photo | video | sidecar | other
    cls TEXT,                            -- primary | secondary | skip
    sidecar INTEGER, twin INTEGER NOT NULL DEFAULT 0, live INTEGER NOT NULL DEFAULT 0,
    -- media: planned > hashed > staged > uploaded > journaled, or copy | live | error; sidecars: planned > parsed | bad
    status TEXT NOT NULL DEFAULT 'planned',
    asset TEXT, sha256 TEXT, info TEXT, jseq INTEGER, captured INTEGER, date_src TEXT, note TEXT);
CREATE INDEX IF NOT EXISTS entries_archive ON entries(archive, offset);
CREATE INDEX IF NOT EXISTS entries_status ON entries(status);
CREATE INDEX IF NOT EXISTS entries_twin ON entries(base, usize);
CREATE INDEX IF NOT EXISTS entries_sidecar ON entries(sidecar);
CREATE TABLE IF NOT EXISTS journal (seq INTEGER PRIMARY KEY, name TEXT NOT NULL, count INTEGER,
    status TEXT NOT NULL, created TEXT);  -- writing > staged > uploaded
"""


class State:
    def __init__(self, path):
        self.dir = os.path.abspath(os.path.expanduser(path))
        os.makedirs(self.dir, exist_ok=True)
        self.lock = open(os.path.join(self.dir, "pv_import.lock"), "w")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            die(f"another pv_import is already using {self.dir}")
        handler = logging.FileHandler(os.path.join(self.dir, "pv_import.log"), encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        for logger in (log, logging.getLogger("py.warnings")):
            logger.addHandler(handler)
            logger.setLevel(logging.DEBUG)
            logger.propagate = False
        logging.captureWarnings(True)
        log.info("pv_import %s", " ".join(sys.argv[1:]))
        self.db = sqlite3.connect(os.path.join(self.dir, "state.sqlite"))
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(SCHEMA)
        self.staging = os.path.join(self.dir, "staging")

    def get(self, key, default=None):
        row = self.db.execute("SELECT v FROM meta WHERE k = ?", (key,)).fetchone()
        return row[0] if row else default

    def put(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, value))
        self.db.commit()


def build_plan(st, source, archives, skip):
    db = st.db
    db.execute("DELETE FROM entries")
    db.execute("DELETE FROM archives")
    found = []
    for name, size in archives:
        say(f"Reading the central directory of {name} ({gb(size)})")
        f = open_archive(source, name, size)
        try:
            with zipfile.ZipFile(f) as zf:
                infos = zf.infolist()
        except (zipfile.BadZipFile, SourceError) as exc:
            die(f"{name}: {exc}")
        finally:
            f.close()
        aid = db.execute("INSERT INTO archives (name, size) VALUES (?, ?)", (name, size)).lastrowid
        found += [(aid, zi) for zi in infos if not zi.is_dir()]
    # Takeout/<Google Photos, possibly localized>/<folder>/<file>
    roots = {zi.filename.split("/")[1] for _, zi in found if zi.filename.count("/") >= 2}
    photo_roots = {r for r in roots if re.search("photo|foto", r, re.IGNORECASE)} or (roots if len(roots) == 1 else set())
    if not photo_roots:
        die("no Google Photos folder in the archives")
    rows, ignored = [], 0
    for aid, zi in found:
        parts = zi.filename.split("/")
        if len(parts) < 3 or parts[1] not in photo_roots:
            ignored += 1
            continue
        base = parts[-1]
        ext = ext_of(base)
        kind = "photo" if ext in PHOTO_MIME else "video" if ext in VIDEO_MIME else "sidecar" if is_sidecar(base) else "other"
        try:
            mtime = time.mktime(zi.date_time + (0, 0, -1))
        except (OverflowError, ValueError):
            mtime = 0
        rows.append((aid, zi.filename, "/".join(parts[2:-1]), base, zi.header_offset, zi.compress_size, zi.file_size,
                     zi.compress_type, mtime, kind))
    db.executemany("INSERT INTO entries (archive, path, folder, base, offset, csize, usize, method, mtime, kind) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
    st.put("source", source)
    st.put("archives", json.dumps(archives))
    analyze(st, skip)
    if ignored:
        say(f"{ignored} archive entries outside Google Photos ignored")


def analyze(st, skip):
    """Folder classes, sidecar pairs, Live Photo parts and probable album copies, from the stored entries."""
    db = st.db
    folders = [r[0] for r in db.execute("SELECT DISTINCT folder FROM entries")]
    db.executemany("UPDATE entries SET cls = ? WHERE folder = ?", [(c, f) for f, c in classify(folders, skip).items()])
    by_folder = {}
    for r in db.execute("SELECT id, folder, base, kind FROM entries WHERE kind != 'other'"):
        by_folder.setdefault(r["folder"], []).append(r)
    pairs, live = [], []
    for rows in by_folder.values():
        media = [(r["id"], r["base"]) for r in rows if r["kind"] in ("photo", "video")]
        found = pair_folder(media, [(r["id"], r["base"]) for r in rows if r["kind"] == "sidecar"])
        pairs += [(found.get(mid), mid) for mid, _ in media]
        stills = {split_ext(r["base"])[0].lower() for r in rows if r["kind"] == "photo"}
        live += [(int(ext_of(r["base"]) in LIVE_VIDEO_EXTS and split_ext(r["base"])[0].lower() in stills), r["id"])
                 for r in rows if r["kind"] == "video"]
    db.executemany("UPDATE entries SET sidecar = ? WHERE id = ?", pairs)
    db.executemany("UPDATE entries SET live = ? WHERE id = ?", live)
    db.execute(f"UPDATE entries SET twin = (cls = 'secondary' AND {MEDIA_SQL} AND EXISTS (SELECT 1 FROM entries p "
               "WHERE p.cls = 'primary' AND p.kind IN ('photo', 'video') AND p.base = entries.base "
               "AND p.usize = entries.usize))")
    st.put("skip_folders", json.dumps(skip))


def ensure_plan(st, source, skip_args):
    planned = st.get("source")
    if planned is not None and planned != source:
        die(f"{st.dir} holds the plan for {planned}; use another --state for {source}")
    archives = [list(a) for a in list_archives(source)]
    stored_skip = json.loads(st.get("skip_folders", "[]"))
    skip = sorted({s.strip().lower() for s in skip_args if s.strip()}) if skip_args else stored_skip
    if json.loads(st.get("archives", "null")) != archives:
        if planned is not None and st.db.execute("SELECT 1 FROM entries WHERE status != 'planned' LIMIT 1").fetchone():
            die("the archives changed after the import started; use a fresh --state directory")
        build_plan(st, source, archives, skip)
    elif skip != stored_skip:
        analyze(st, skip)


def summary(st, keep_live=False, trust=False):
    db = st.db
    rank = {"primary": 0, "secondary": 1, "skip": 2}
    rows = sorted(db.execute("SELECT folder, cls, COUNT(*) AS n, COALESCE(SUM(usize), 0) AS b FROM entries "
                             "GROUP BY folder, cls").fetchall(), key=lambda r: (rank.get(r["cls"], 3), r["folder"].lower()))
    width = min(max([len(r["folder"]) for r in rows] + [11]), 48)
    out = [f"{'Folder':<{width}}  {'Class':<9} {'Files':>7} {'Size':>10}"]
    for r in rows:
        name = r["folder"] or "(top level)"
        name = name if len(name) <= width else name[:width - 1] + "…"
        out.append(f"{name:<{width}}  {r['cls']:<9} {r['n']:>7} {gb(r['b']):>10}")

    def one(sql):
        return db.execute(sql).fetchone()

    wanted = f"{MEDIA_SQL} AND (cls = 'primary' OR (cls = 'secondary' AND twin = 0))"
    todo = wanted + ("" if keep_live else " AND live = 0")
    n, size = one(f"SELECT COUNT(*), COALESCE(SUM(usize), 0) FROM entries WHERE {todo}")
    no_sidecar = one(f"SELECT COUNT(*) FROM entries WHERE {todo} AND sidecar IS NULL")[0]
    copies = one(f"SELECT COUNT(*) FROM entries WHERE {MEDIA_SQL} AND twin = 1")[0]
    orphans = one("SELECT COUNT(*) FROM entries s WHERE kind = 'sidecar' AND cls != 'skip' "
                  "AND NOT EXISTS (SELECT 1 FROM entries m WHERE m.sidecar = s.id)")[0]
    trash = one("SELECT COUNT(*) FROM entries WHERE cls = 'skip'")[0]
    live = one(f"SELECT COUNT(*) FROM entries WHERE {wanted} AND live = 1")[0]
    upload = size + size // CHUNK * 16 + n * (2 * 40 + 40_000 + 400)  # tags, headers, ~40 KB thumb, journal
    out += ["",
            f"Media to import        {n:>8}  {gb(size)}; {no_sidecar} without sidecar (EXIF/ffprobe/folder date)",
            f"Probable album copies  {copies:>8}  ({'skipped by name + size' if trust else 'skipped if sha256 matches'})",
            f"Unmatched sidecars     {orphans:>8}",
            f"Skipped (trash) files  {trash:>8}",
            f"Live-video parts       {live:>8}  ({'imported' if keep_live else 'skipped if ≤ 3.5 s'})",
            f"Estimated upload       {gb(upload):>11}"]
    done = db.execute(f"SELECT status, COUNT(*) FROM entries WHERE {MEDIA_SQL} AND status != 'planned' GROUP BY status")
    done = ", ".join(f"{s} {c}" for s, c in done)
    if done:
        out.append(f"Progress so far        {done}")
    return "\n".join(out)


def check_key(st, master, dest, prompted):
    """Refuse a recovery string that does not open the vault's journal, or differs from earlier runs."""
    fingerprint = hmac.new(master, b"pv_import key fingerprint", hashlib.sha256).hexdigest()[:16]
    known = st.get("key_fingerprint")
    if known and known != fingerprint:
        die("this is not the recovery string used by earlier runs with this state directory")
    verified = False
    for size, rel in sorted(vault_journal_files(dest))[:5]:
        m = JOURNAL_NAME_RE.match(rel.rsplit("/", 1)[-1])
        if not m or size > 8 << 20:
            continue
        try:
            open_blob(read_dest(dest, "journal/" + rel), master, m.group(1))
        except InvalidTag:
            die(f"the recovery string cannot decrypt journal/{rel}: wrong recovery string or wrong vault")
        except ValueError:
            continue
        say(f"Recovery string verified against journal/{rel}.")
        verified = True
        break
    if not verified and not known:
        say("Warning: the vault has no journal yet, so the recovery string cannot be checked against it.")
        if prompted and master_key_from_recovery(getpass.getpass("Repeat the recovery string: ")) != master:
            die("the two recovery strings differ")
    st.put("key_fingerprint", fingerprint)


# ---------------------------------------------------------------- upload


def staged_files(root):
    """{path: size} of the finished files in staging (tmp excluded)."""
    found = {}
    for sub in ("originals", "thumbs", "journal"):
        for dirpath, _, names in os.walk(os.path.join(root, sub)):
            for name in names:
                path = os.path.join(dirpath, name)
                try:
                    found[path] = os.path.getsize(path)
                except OSError:
                    pass
    return found


def staging_bytes(root):
    return sum(staged_files(root).values())


class Uploader(threading.Thread):
    """Moves finished blobs and journal files from staging into the vault every 15 s, or when kicked.
    A file that has left staging counts as uploaded."""

    def __init__(self, staging, dest):
        super().__init__(daemon=True)
        self.staging, self.dest = staging, dest
        self.kick, self.halt = threading.Event(), threading.Event()
        self.cond, self.lock = threading.Condition(), threading.Lock()
        self.generation = self.uploaded = self.failures = 0

    def run(self):
        while not self.halt.is_set():
            self.kick.wait(UPLOAD_EVERY)
            self.kick.clear()
            if not self.halt.is_set():
                self.move_once()

    def move_once(self):
        with self.lock:
            before = staged_files(self.staging)
            try:
                ok = self._move(before) if before else True
            except Exception:
                log.exception("upload failed")
                ok = False
            moved = sum(size for path, size in before.items() if not os.path.exists(path))
            with self.cond:
                self.uploaded += moved
                self.failures = 0 if ok else self.failures + 1
                self.generation += 1
                self.cond.notify_all()
            return ok

    def _move(self, files):
        if is_remote(self.dest):
            # --no-traverse: check each new file instead of listing the ever-growing originals/ and thumbs/.
            cmd = ["rclone", "move", self.staging, self.dest, "--include", "originals/**", "--include", "thumbs/**",
                   "--include", "journal/**", "--transfers", "4", "--retries", "5", "--low-level-retries", "20",
                   "--no-traverse"]
            try:
                p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, start_new_session=True)
            except OSError as exc:
                log.error("rclone move: %s", exc)
                return False
            if p.stderr.strip():
                log.info("rclone move: %s", p.stderr.strip()[-4000:])
            if p.returncode:
                log.error("rclone move exited with %d", p.returncode)
            return p.returncode == 0
        ok = True
        for path in files:
            target = os.path.join(self.dest, os.path.relpath(path, self.staging))
            try:
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.move(path, target)
            except OSError as exc:
                log.error("move %s: %s", path, exc)
                ok = False
        return ok


# ---------------------------------------------------------------- run


class Importer:
    def __init__(self, st, args, master, device):
        self.st, self.db = st, st.db
        self.source, self.master, self.device = args.source, master, device
        self.limit, self.trust, self.keep_live = args.limit, args.trust_copies, args.keep_live_videos
        self.cap = int(args.staging_cap_gb * 1e9)
        self.tmp = os.path.join(st.staging, "tmp")
        self.orig_dir = os.path.join(st.staging, "originals")
        self.thumb_dir = os.path.join(st.staging, "thumbs")
        self.jdir = os.path.join(st.staging, "journal", device)
        for d in (self.tmp, self.orig_dir, self.thumb_dir, self.jdir):
            os.makedirs(d, exist_ok=True)
        self.ffprobe, self.ffmpeg = shutil.which("ffprobe"), shutil.which("ffmpeg")
        self.uploader = Uploader(st.staging, args.dest)
        self.stop_reason = None  # interrupt | limit | source
        self.interrupts = 0
        self.counts = {"imported": 0, "copy": 0, "live": 0, "error": 0}
        self.files_done = self.work_done = self.read_done = self.seen_generation = 0
        self.total_files = self.total_bytes = 0
        self.reader = None
        self.started = self.last_flush = time.monotonic()

    def run(self):
        def on_signal(signum, frame):
            self.interrupts += 1
            if self.interrupts > 1:
                raise KeyboardInterrupt
            self.stop_reason = self.stop_reason or "interrupt"
            print("\nStopping after the current file (Ctrl-C again aborts at once) ...", flush=True)

        signal.signal(signal.SIGINT, on_signal)
        signal.signal(signal.SIGTERM, on_signal)
        self.recover()
        self.total_files, self.total_bytes = self.db.execute(
            f"SELECT COUNT(*), COALESCE(SUM(usize), 0) FROM entries WHERE {MEDIA_SQL} AND status = 'planned' AND "
            f"(cls = 'primary' OR (cls = 'secondary'{' AND twin = 0' if self.trust else ''}))").fetchone()
        self.uploader.start()
        complete = False
        try:
            for pass_no in (1, 2):  # 1: year folders; 2: albums and the rest
                for arch in self.db.execute("SELECT * FROM archives ORDER BY name").fetchall():
                    if self.stop_reason:
                        break
                    if not arch[f"done{pass_no}"]:
                        self.process_archive(arch, pass_no)
            complete = self.stop_reason is None
        except SourceError as exc:
            self.stop_reason = "source"
            say(f"Source unavailable, stopping: {exc}")
        except Fatal:
            self.finish(False)
            raise
        self.finish(complete)
        return 1 if self.stop_reason == "source" else 0

    def recover(self):
        """Bring state and staging back in line after an interrupted run."""
        db = self.db
        for j in db.execute("SELECT seq, name FROM journal WHERE status = 'writing'").fetchall():
            if os.path.exists(os.path.join(self.jdir, j["name"])):
                db.execute("UPDATE journal SET status = 'staged' WHERE seq = ?", (j["seq"],))
            elif os.path.exists(os.path.join(self.tmp, j["name"])):  # never left tmp: forget it
                db.execute("UPDATE entries SET jseq = NULL WHERE jseq = ?", (j["seq"],))
                db.execute("DELETE FROM journal WHERE seq = ?", (j["seq"],))
            else:  # renamed into staging and already moved to the vault
                db.execute("UPDATE journal SET status = 'uploaded' WHERE seq = ?", (j["seq"],))
        shutil.rmtree(self.tmp, ignore_errors=True)
        os.makedirs(self.tmp)
        staged = {r[0] for r in db.execute("SELECT asset FROM entries WHERE status = 'staged'")}
        for d in (self.orig_dir, self.thumb_dir):
            for name in os.listdir(d):
                if name[:-4] not in staged:  # blob of an unfinished entry, redone under the same asset id
                    os.remove(os.path.join(d, name))
        if self.keep_live:
            db.execute("UPDATE entries SET status = 'planned' WHERE status = 'live'")
        db.execute("UPDATE entries SET status = 'planned' WHERE status IN ('hashed', 'error')")
        for n, cls in ((1, "primary"), (2, "secondary")):
            db.execute(f"UPDATE archives SET done{n} = 0 WHERE id IN (SELECT archive FROM entries "
                       f"WHERE status = 'planned' AND cls = ? AND {MEDIA_SQL})", (cls,))
        db.commit()
        self.reconcile()

    def process_archive(self, arch, pass_no):
        db, cls = self.db, ("primary" if pass_no == 1 else "secondary")
        if pass_no == 2 and self.trust:
            self.counts["copy"] += db.execute(
                "UPDATE entries SET status = 'copy', note = 'same name and size as a year-folder file' "
                f"WHERE archive = ? AND twin = 1 AND status = 'planned' AND {MEDIA_SQL}", (arch["id"],)).rowcount
            db.commit()
        media = db.execute(f"SELECT * FROM entries WHERE archive = ? AND cls = ? AND {MEDIA_SQL} AND status = 'planned'",
                           (arch["id"], cls)).fetchall()
        sidecars = db.execute(
            "SELECT * FROM entries s WHERE archive = ? AND kind = 'sidecar' AND status = 'planned' AND EXISTS "
            "(SELECT 1 FROM entries m WHERE m.sidecar = s.id AND m.cls = ? "
            "AND m.status IN ('planned', 'hashed', 'staged', 'uploaded'))", (arch["id"], cls)).fetchall()
        finished = True
        if media or sidecars:
            say(f"Pass {pass_no} · {arch['name']}: {len(media)} media, {len(sidecars)} sidecars")
            finished = self.read_archive(arch, sorted(media + sidecars, key=lambda r: r["offset"]), pass_no)
        if finished:
            db.execute(f"UPDATE archives SET done{pass_no} = 1 WHERE id = ?", (arch["id"],))
            db.commit()
            self.after_item()
            self.flush_journal(force=True)
            if media or sidecars:
                self.progress(f"{arch['name']} pass {pass_no} done")

    def read_archive(self, arch, work, pass_no):
        """Handle the work entries of one archive in header-offset order; False if stopped early."""
        f = open_archive(self.source, arch["name"], arch["size"])
        self.reader = f
        try:
            try:
                zf = zipfile.ZipFile(f)
            except zipfile.BadZipFile as exc:
                die(f"{arch['name']}: {exc}")
            infos = {zi.header_offset: zi for zi in zf.infolist()}
            for e in work:
                if self.stop_reason:
                    return False
                zi = infos.get(e["offset"])
                if zi is None or zi.filename != e["path"]:
                    die(f"{arch['name']} no longer matches the plan ({e['path']}); use a fresh --state directory")
                if e["kind"] == "sidecar":
                    self.read_sidecar(e, zf, zi)
                else:
                    self.wait_for_room()
                    if self.stop_reason:
                        return False
                    self.handle_media(e, zf, zi, pass_no)
                self.after_item()
            return True
        finally:
            self.read_done += f.bytes_read
            self.reader = None
            f.close()

    def read_sidecar(self, e, zf, zi):
        try:
            if (e["usize"] or 0) > SIDECAR_MAX:
                raise ValueError("too large for a sidecar")
            with zf.open(zi) as f:
                parsed = parse_sidecar(f.read())
            self.db.execute("UPDATE entries SET status = 'parsed', info = ? WHERE id = ?", (json.dumps(parsed), e["id"]))
        except SourceError:
            raise
        except Exception as exc:
            log.warning("sidecar %s unreadable: %s", e["path"], exc)
            self.db.execute("UPDATE entries SET status = 'bad', note = ? WHERE id = ?", (str(exc)[:300], e["id"]))
        self.db.commit()

    def handle_media(self, e, zf, zi, pass_no):
        try:
            outcome = self.import_media(e, zf, zi, pass_no)
        except (SourceError, Fatal):
            raise
        except Exception as exc:
            if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
                die(f"disk full while staging {e['path']}; free space or lower --staging-cap-gb")
            log.exception("failed: %s", e["path"])
            self.db.execute("UPDATE entries SET status = 'error', note = ? WHERE id = ?",
                            (f"{type(exc).__name__}: {exc}"[:500], e["id"]))
            self.db.commit()
            outcome = "error"
        self.counts[outcome] += 1
        if outcome == "imported" and self.limit and self.counts["imported"] >= self.limit:
            self.stop_reason = self.stop_reason or "limit"
        self.files_done += 1
        self.work_done += e["usize"] or 0
        if self.files_done % 25 == 0:
            self.progress()

    def import_media(self, e, zf, zi, pass_no):
        db = self.db
        asset = e["asset"] or str(uuid.uuid4())
        if e["asset"] is None:
            db.execute("UPDATE entries SET asset = ? WHERE id = ?", (asset, e["id"]))
            db.commit()
        ext = ext_of(e["base"])
        spool = os.path.join(self.tmp, asset + ".src")
        sealed = (os.path.join(self.tmp, asset + ".orig.enc"), os.path.join(self.tmp, asset + ".thumb.enc"))
        try:
            digest, data, size = hashlib.sha256(), None, 0
            with zf.open(zi) as src:
                if e["kind"] == "photo" and (e["usize"] or 0) <= BIG_PHOTO:
                    data = src.read()
                    digest.update(data)
                    size = len(data)
                else:  # videos (and huge photos) are spooled; plaintext never stays longer than this file
                    with open(spool, "wb") as out:
                        while buf := src.read(1 << 20):
                            digest.update(buf)
                            out.write(buf)
                            size += len(buf)
            sha = digest.hexdigest()
            db.execute("UPDATE entries SET status = 'hashed', sha256 = ? WHERE id = ?", (sha, e["id"]))
            db.commit()
            if pass_no == 2 and e["twin"] and sha in {r[0] for r in db.execute(
                    f"SELECT sha256 FROM entries WHERE cls = 'primary' AND {MEDIA_SQL} AND base = ? AND usize = ?",
                    (e["base"], e["usize"]))}:
                return self.skip(e, "copy", "byte-identical to a year-folder file")
            if e["kind"] == "video":
                info = video_info(spool, self.ffprobe)
                if e["live"] and not self.keep_live and info["duration"] is not None \
                        and info["duration"] <= LIVE_MAX_SECONDS:
                    return self.skip(e, "live", f"Live Photo motion part ({info['duration']:.2f} s)")
                meta = {"width": info["width"], "height": info["height"], "duration": round(info["duration"] or 0.0, 3),
                        "created": info["created"], "created_src": info["created_src"]}
                thumb = video_thumb(spool, info["duration"], self.ffmpeg)
            else:
                width, height, taken, thumb = photo_info(data if data is not None else spool, ext)
                meta = {"width": width, "height": height, "duration": 0.0, "exif": taken}
            if thumb is None:
                log.info("placeholder thumbnail for %s", e["path"])
                thumb = placeholder_thumb(ext)
            meta.update(mime=MIME[ext], bytes=size)
            aead = blob_aead(self.master, asset)
            if data is not None:
                nonce = seal_blob(data, size, sealed[0], aead)
            else:
                with open(spool, "rb") as plain:
                    nonce = seal_blob(plain, size, sealed[0], aead)
            seal_blob(thumb, len(thumb), sealed[1], aead, avoid_nonce=nonce)
            os.replace(sealed[1], os.path.join(self.thumb_dir, asset + ".enc"))
            os.replace(sealed[0], os.path.join(self.orig_dir, asset + ".enc"))
            db.execute("UPDATE entries SET status = 'staged', info = ? WHERE id = ?", (json.dumps(meta), e["id"]))
            db.commit()
            log.info("staged %s as %s (%d bytes, %dx%d)", e["path"], asset, size, meta["width"], meta["height"])
            return "imported"
        finally:
            for path in (spool, *sealed):
                if os.path.exists(path):
                    os.remove(path)

    def skip(self, e, status, note):
        self.db.execute("UPDATE entries SET status = ?, note = ? WHERE id = ?", (status, note, e["id"]))
        self.db.commit()
        log.info("skipped %s: %s", e["path"], note)
        return status

    def wait_for_room(self):
        warned = 0.0
        while not self.stop_reason and staging_bytes(self.st.staging) > self.cap:
            generation = self.uploader.generation
            self.uploader.kick.set()
            with self.uploader.cond:
                self.uploader.cond.wait_for(lambda: self.uploader.generation != generation, timeout=5)
            self.after_item()
            if self.uploader.failures >= 2 and time.monotonic() - warned > 300:
                say("Uploads are failing (details in the log); retrying.")
                warned = time.monotonic()

    def after_item(self):
        if self.uploader.generation != self.seen_generation:
            self.seen_generation = self.uploader.generation
            self.reconcile()
            self.flush_journal()

    def reconcile(self):
        """Blobs and journal files that have left staging are uploaded; a journal upload journals its entries."""
        db = self.db
        gone = [(r["id"],) for r in db.execute("SELECT id, asset FROM entries WHERE status = 'staged'").fetchall()
                if not os.path.exists(os.path.join(self.orig_dir, r["asset"] + ".enc"))
                and not os.path.exists(os.path.join(self.thumb_dir, r["asset"] + ".enc"))]
        db.executemany("UPDATE entries SET status = 'uploaded' WHERE id = ?", gone)
        for j in db.execute("SELECT seq, name FROM journal WHERE status = 'staged'").fetchall():
            if not os.path.exists(os.path.join(self.jdir, j["name"])):
                db.execute("UPDATE journal SET status = 'uploaded' WHERE seq = ?", (j["seq"],))
        db.execute("UPDATE entries SET status = 'journaled' WHERE status = 'uploaded' "
                   "AND jseq IN (SELECT seq FROM journal WHERE status = 'uploaded')")
        db.commit()

    def flush_journal(self, force=False, final=False):
        """Journal uploaded assets whose sidecar is settled (all of them when final), ≤ 500 entries per file."""
        rows = self.db.execute("SELECT e.*, s.status AS sc_status, s.info AS sc_info FROM entries e "
                               "LEFT JOIN entries s ON s.id = e.sidecar "
                               "WHERE e.status = 'uploaded' AND e.jseq IS NULL ORDER BY e.id").fetchall()
        ready = [r for r in rows if final or r["sidecar"] is None or r["sc_status"] in ("parsed", "bad")]
        if not ready or (not force and len(ready) < JOURNAL_MAX and time.monotonic() - self.last_flush < 600):
            return
        now, batch, members = time.time(), [], []
        for r in ready:
            ops, captured, source = self.journal_ops(r, now)
            if len(batch) + len(ops) > JOURNAL_MAX:
                self.write_journal(batch, members)
                batch, members = [], []
            batch += ops
            members.append((r["id"], captured, source))
        self.write_journal(batch, members)
        self.last_flush = time.monotonic()
        self.uploader.kick.set()

    def journal_ops(self, r, now):
        info = json.loads(r["info"])
        sc = json.loads(r["sc_info"]) if r["sc_status"] == "parsed" and r["sc_info"] else {}
        captured, source = capture_time(r, info, sc)
        meta = {"filename": journal_filename(r["base"], sc.get("title")), "kind": r["kind"], "mime": info["mime"],
                "captured": iso(captured), "width": int(info["width"]), "height": int(info["height"]),
                "duration": float(info["duration"]), "bytes": int(info["bytes"]), "sha256": r["sha256"],
                "sourceAssetId": ""}
        # JournalMeta is a synthesized Codable, so the app's JSONDecoder ignores these extra keys.
        if "lat" in sc:
            meta["lat"], meta["lon"] = sc["lat"], sc["lon"]
        if sc.get("description"):
            meta["description"] = sc["description"]
        ops = [{"op": "add", "id": r["asset"], "ts": iso(now), "device": self.device, "meta": meta}]
        if sc.get("favorited") is True:  # later ts: the app applies an op only if ts >= the asset's last one
            ops.append({"op": "favorite", "id": r["asset"], "ts": iso(now + 1), "device": self.device})
        return ops, int(captured), source

    def write_journal(self, batch, members):
        db = self.db
        seq = (db.execute("SELECT MAX(seq) FROM journal").fetchone()[0] or 0) + 1
        blob = str(uuid.uuid4())
        name = f"{seq:06d}-{blob}.enc"  # JournalCoding.journalFilename; the blob id is the UUID in the name
        payload = json.dumps(batch, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        tmp = os.path.join(self.tmp, name)
        seal_blob(payload, len(payload), tmp, blob_aead(self.master, blob))
        db.execute("INSERT INTO journal (seq, name, count, status, created) VALUES (?, ?, ?, 'writing', ?)",
                   (seq, name, len(batch), iso(time.time())))
        db.executemany("UPDATE entries SET jseq = ?, captured = ?, date_src = ? WHERE id = ?",
                       [(seq, captured, source, eid) for eid, captured, source in members])
        db.commit()
        os.replace(tmp, os.path.join(self.jdir, name))
        db.execute("UPDATE journal SET status = 'staged' WHERE seq = ?", (seq,))
        db.commit()
        log.info("journal %s: %d entries", name, len(batch))

    def fetch_pending_sidecars(self):
        """Sidecars of already imported files that the stream has not reached (a stopped or limited run)."""
        rows = self.db.execute("SELECT DISTINCT s.* FROM entries e JOIN entries s ON s.id = e.sidecar "
                               "WHERE e.status IN ('staged', 'uploaded') AND e.jseq IS NULL AND s.status = 'planned' "
                               "ORDER BY s.archive, s.offset LIMIT 2000").fetchall()
        if not rows:
            return
        say(f"Reading {len(rows)} sidecars of imported files directly")
        archives = {a["id"]: a for a in self.db.execute("SELECT * FROM archives")}
        for aid in dict.fromkeys(r["archive"] for r in rows):
            arch = archives[aid]
            f = open_archive(self.source, arch["name"], arch["size"])
            try:
                zf = zipfile.ZipFile(f)
                infos = {zi.header_offset: zi for zi in zf.infolist()}
                for s in rows:
                    if s["archive"] == aid and s["offset"] in infos:
                        self.read_sidecar(s, zf, infos[s["offset"]])
            except (SourceError, zipfile.BadZipFile) as exc:
                log.warning("cannot read sidecars from %s: %s", arch["name"], exc)
            finally:
                self.read_done += f.bytes_read
                f.close()

    def drain(self):
        for attempt in range(4):
            if not staged_files(self.st.staging):
                break
            if attempt:
                time.sleep(10 * attempt)
            self.uploader.move_once()
        self.reconcile()

    def finish(self, complete):
        """Final upload, sidecars still missing, journal flush (fallback dates once everything is read), upload."""
        self.uploader.halt.set()
        self.uploader.kick.set()
        self.uploader.join()
        self.drain()
        if self.stop_reason != "source":
            self.fetch_pending_sidecars()
        self.flush_journal(force=True, final=complete)
        self.drain()
        c = self.counts
        self.progress("finished" if complete else f"stopped ({self.stop_reason})")
        say(f"This run: {c['imported']} imported, {c['copy']} album copies and {c['live']} Live Photo videos skipped, "
            f"{c['error']} errors (see {os.path.join(self.st.dir, 'pv_import.log')}).")
        totals = self.db.execute(f"SELECT status, COUNT(*) FROM entries WHERE {MEDIA_SQL} AND cls != 'skip' GROUP BY status")
        say("All runs: " + ", ".join(f"{s} {n}" for s, n in totals))
        sources = self.db.execute("SELECT date_src, COUNT(*) FROM entries WHERE date_src IS NOT NULL GROUP BY date_src")
        say("Capture dates from: " + ", ".join(f"{s} {n}" for s, n in sources))
        waiting = self.db.execute("SELECT COUNT(*) FROM entries WHERE status IN ('staged', 'uploaded')").fetchone()[0]
        if waiting:
            say(f"{waiting} imported files still await upload or their journal entry; the next run completes them.")
        if not complete:
            say("Run the same command again to continue.")

    def progress(self, note=""):
        read = self.read_done + (self.reader.bytes_read if self.reader else 0)
        left = self.total_bytes - self.work_done
        elapsed = time.monotonic() - self.started
        eta = hms(elapsed * left / self.work_done) if self.work_done and left > 0 else "--"
        say(f"{note + ' | ' if note else ''}{self.files_done}/{self.total_files} files | read {gb(read)} | "
            f"uploaded {gb(self.uploader.uploaded)} | staging {gb(staging_bytes(self.st.staging))} | ETA {eta}")


# ---------------------------------------------------------------- commands


def cmd_plan(args):
    need_rclone(args.source)
    st = State(args.state)
    ensure_plan(st, args.source, args.skip_folder)
    print(summary(st))
    return 0


def cmd_run(args):
    if Image is None:
        die("Pillow is missing: pip install -r tools/requirements.txt")
    need_rclone(args.source, args.dest)
    st = State(args.state)
    ensure_plan(st, args.source, args.skip_folder)
    print(summary(st, args.keep_live_videos, args.trust_copies))
    if not args.yes and not confirm("\nStart the import? [y/N] "):
        return 1
    master, prompted = read_recovery(args.recovery_file)
    check_key(st, master, args.dest, prompted)
    device = st.get("device_id")
    if device is None:
        device = str(uuid.uuid4())
        st.put("device_id", device)
    if pillow_heif is None:
        say("Warning: pillow-heif is not installed; HEIC photos get placeholder thumbnails and no size.")
    if not (shutil.which("ffprobe") and shutil.which("ffmpeg")):
        say("Warning: ffmpeg/ffprobe not found; video facts come from MP4/MOV headers, video thumbnails are placeholders.")
    return Importer(st, args, master, device).run()


def cmd_verify(args):
    need_rclone(args.dest)
    st = State(args.state)
    device = st.get("device_id")
    if device is None:
        die("nothing has been imported with this state directory")
    originals, thumbs = dest_names(args.dest, "originals"), dest_names(args.dest, "thumbs")
    journal = dest_names(args.dest, f"journal/{device}")
    rows = st.db.execute("SELECT e.path, e.asset, e.status, j.name AS jname FROM entries e "
                         "LEFT JOIN journal j ON j.seq = e.jseq WHERE e.kind IN ('photo', 'video') "
                         "AND e.status IN ('staged', 'uploaded', 'journaled')").fetchall()
    problems = []
    for r in rows:
        blob = r["asset"] + ".enc"
        lacking = [what for what, ok in (("original", blob in originals), ("thumb", blob in thumbs),
                                         ("journal entry", r["status"] == "journaled" and r["jname"] in journal)) if not ok]
        if lacking:
            problems.append(f"{r['asset']}  {r['path']}: no {', '.join(lacking)}")
    files = st.db.execute("SELECT name FROM journal WHERE status IN ('staged', 'uploaded')").fetchall()
    problems += [f"journal/{device}/{j['name']}: missing" for j in files if j["name"] not in journal]
    problems += [f"{e['path']}: import failed ({e['note']})"
                 for e in st.db.execute("SELECT path, note FROM entries WHERE status = 'error'")]
    pending = st.db.execute(f"SELECT COUNT(*) FROM entries WHERE {MEDIA_SQL} AND status = 'planned' "
                            "AND cls != 'skip'").fetchone()[0]
    for line in problems:
        log.warning("verify: %s", line)
    for line in problems[:50]:
        print(line)
    if len(problems) > 50:
        print(f"... {len(problems) - 50} more in {os.path.join(st.dir, 'pv_import.log')}")
    say(f"Checked {len(rows)} imported assets and {len(files)} journal files: {len(problems)} problems"
        + (f"; {pending} media not imported yet." if pending else "."))
    return 1 if problems else 0


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Import a Google Takeout (Google Photos) export into a PhotoVault vault.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    plan = sub.add_parser("plan", help="read the archives' central directories and show what would be imported")
    run = sub.add_parser("run", help="import (plans first if needed); resumable")
    verify = sub.add_parser("verify", help="compare the vault with the local state")
    for p in (plan, run):
        p.add_argument("--source", required=True, help="rclone remote path or local directory with the Takeout .zip files")
        p.add_argument("--skip-folder", action="append", default=[], metavar="NAME",
                       help="skip this folder too (besides Trash/Bin/...); repeatable")
    for p in (run, verify):
        p.add_argument("--dest", required=True, help="the vault, e.g. hidrive:PhotoVault, or a local directory")
    for p in (plan, run, verify):
        p.add_argument("--state", required=True, help="state directory: state.sqlite, staging/, pv_import.log")
    run.add_argument("--limit", type=int, default=0, metavar="N", help="stop after N imported media (trial run)")
    run.add_argument("--staging-cap-gb", type=float, default=8.0, metavar="GB")
    copies = run.add_mutually_exclusive_group()
    copies.add_argument("--verify-copies", dest="trust_copies", action="store_false",
                        help="skip an album copy only if its sha256 equals the year-folder file's (default)")
    copies.add_argument("--trust-copies", dest="trust_copies", action="store_true",
                        help="skip album copies by name and size without reading them")
    run.set_defaults(trust_copies=False)
    run.add_argument("--keep-live-videos", action="store_true", help="also import Live Photo motion parts")
    run.add_argument("--recovery-file", metavar="PATH", help="file with the recovery string (mode 600); "
                                                             "else $PV_RECOVERY, else a prompt")
    run.add_argument("--yes", action="store_true", help="do not ask for confirmation")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        return {"plan": cmd_plan, "run": cmd_run, "verify": cmd_verify}[args.cmd](args)
    except Fatal as exc:
        log.error("%s", exc)
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        log.warning("aborted")
        print("\naborted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
