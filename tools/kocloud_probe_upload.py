#!/usr/bin/env python3
"""
KOCloud companion feasibility probe.

Purpose:
1. Authorize on a PC with the SAME Google OAuth client JSON used by KOCloud.
2. Use only the drive.file scope.
3. Verify that this session can see the KOCloud root and Books folder that
   were already created by the KOReader plugin.
4. If visible, upload exactly one EPUB/PDF into KOCloud/Books.

The script deliberately DOES NOT create missing KOCloud folders.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import time
from pathlib import Path
from typing import Any

try:
    import requests
except ImportError:
    print(
        "ERROR: This probe requires the 'requests' package.\n"
        "Install it with:\n"
        "  python -m pip install requests",
        file=sys.stderr,
    )
    raise SystemExit(2)


DEVICE_CODE_URL = "https://oauth2.googleapis.com/device/code"
TOKEN_URL = "https://oauth2.googleapis.com/token"
DRIVE_FILES_URL = "https://www.googleapis.com/drive/v3/files"
DRIVE_UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files"

SCOPE = "https://www.googleapis.com/auth/drive.file"
FOLDER_MIME = "application/vnd.google-apps.folder"

ROLE_KEY = "kocloud_role"
SCHEMA_KEY = "kocloud_schema"
SCHEMA_VERSION = "1"


class ProbeError(RuntimeError):
    pass


def load_oauth_client(path: Path) -> tuple[str, str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ProbeError(f"Cannot read OAuth JSON: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ProbeError(f"OAuth file is not valid JSON: {exc}") from exc

    if isinstance(data.get("installed"), dict):
        block = data["installed"]
    elif isinstance(data.get("web"), dict):
        block = data["web"]
    else:
        block = data

    client_id = block.get("client_id")
    client_secret = block.get("client_secret")

    if not isinstance(client_id, str) or not client_id:
        raise ProbeError("OAuth JSON does not contain client_id")
    if not isinstance(client_secret, str) or not client_secret:
        raise ProbeError("OAuth JSON does not contain client_secret")

    return client_id, client_secret


def request_device_authorization(client_id: str) -> dict[str, Any]:
    response = requests.post(
        DEVICE_CODE_URL,
        data={"client_id": client_id, "scope": SCOPE},
        timeout=30,
    )
    if not response.ok:
        raise ProbeError(
            f"Device authorization failed ({response.status_code}): "
            f"{response.text}"
        )

    payload = response.json()
    for key in ("device_code", "user_code", "verification_url"):
        if not payload.get(key):
            raise ProbeError(f"Google device response is missing {key}")
    return payload


def poll_for_access_token(
    client_id: str,
    client_secret: str,
    session: dict[str, Any],
) -> str:
    interval = int(session.get("interval", 5))
    deadline = time.monotonic() + int(session.get("expires_in", 1800))

    while time.monotonic() < deadline:
        time.sleep(interval)
        response = requests.post(
            TOKEN_URL,
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "device_code": session["device_code"],
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            },
            timeout=30,
        )

        payload = response.json()
        if response.ok and payload.get("access_token"):
            return str(payload["access_token"])

        error = payload.get("error")
        if error == "authorization_pending":
            print(".", end="", flush=True)
            continue
        if error == "slow_down":
            interval += 5
            print("s", end="", flush=True)
            continue
        if error == "access_denied":
            raise ProbeError("Google authorization was denied")
        if error == "expired_token":
            raise ProbeError("Google device authorization code expired")

        raise ProbeError(
            "Token polling failed: "
            + json.dumps(payload, ensure_ascii=False)
        )

    raise ProbeError("Google device authorization timed out")


def auth_headers(access_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {access_token}"}


def drive_list(access_token: str, query: str) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    page_token: str | None = None

    while True:
        params = {
            "q": query,
            "spaces": "drive",
            "pageSize": 100,
            "fields": (
                "nextPageToken,"
                "files(id,name,mimeType,parents,appProperties)"
            ),
        }
        if page_token:
            params["pageToken"] = page_token

        response = requests.get(
            DRIVE_FILES_URL,
            headers=auth_headers(access_token),
            params=params,
            timeout=30,
        )
        if not response.ok:
            raise ProbeError(
                f"Drive list failed ({response.status_code}): "
                f"{response.text}"
            )

        payload = response.json()
        result.extend(payload.get("files", []))
        page_token = payload.get("nextPageToken")
        if not page_token:
            break

    return result


def find_kocloud_root(access_token: str) -> dict[str, Any]:
    query = (
        f"mimeType='{FOLDER_MIME}' and trashed=false "
        f"and appProperties has {{ key='{ROLE_KEY}' and value='root' }}"
    )
    roots = drive_list(access_token, query)

    if not roots:
        visible_folders = drive_list(
            access_token,
            f"mimeType='{FOLDER_MIME}' and trashed=false",
        )
        names = ", ".join(
            sorted(folder.get("name", "?") for folder in visible_folders)[:20]
        )
        raise ProbeError(
            "This PC authorization cannot see the existing KOCloud root "
            "created by the KOReader plugin.\n"
            f"Accessible folders: {names or '(none)'}"
        )

    if len(roots) != 1:
        raise ProbeError(
            f"Found {len(roots)} KOCloud roots; refusing to guess."
        )

    return roots[0]


def find_books_folder(
    access_token: str,
    root_id: str,
) -> dict[str, Any]:
    query = (
        f"'{root_id}' in parents and "
        f"mimeType='{FOLDER_MIME}' and trashed=false "
        f"and appProperties has {{ key='{ROLE_KEY}' and value='books' }}"
    )
    folders = drive_list(access_token, query)

    if not folders:
        raise ProbeError(
            "The KOCloud root is visible, but the managed Books folder "
            "is not visible."
        )

    if len(folders) != 1:
        raise ProbeError(
            f"Found {len(folders)} managed Books folders; refusing to guess."
        )

    return folders[0]


def guess_mime(path: Path) -> str:
    if path.suffix.lower() == ".epub":
        return "application/epub+zip"
    if path.suffix.lower() == ".pdf":
        return "application/pdf"

    guessed, _ = mimetypes.guess_type(path.name)
    return guessed or "application/octet-stream"


def upload_book(
    access_token: str,
    book_path: Path,
    books_folder_id: str,
) -> dict[str, Any]:
    mime_type = guess_mime(book_path)
    size = book_path.stat().st_size

    metadata = {
        "name": book_path.name,
        "parents": [books_folder_id],
        "appProperties": {
            ROLE_KEY: "book",
            SCHEMA_KEY: SCHEMA_VERSION,
            "kocloud_source": "companion_probe",
        },
    }

    response = requests.post(
        DRIVE_UPLOAD_URL,
        headers={
            **auth_headers(access_token),
            "Content-Type": "application/json; charset=UTF-8",
            "X-Upload-Content-Type": mime_type,
            "X-Upload-Content-Length": str(size),
        },
        params={
            "uploadType": "resumable",
            "fields": "id,name,parents,appProperties,size,modifiedTime",
        },
        json=metadata,
        timeout=30,
    )

    if not response.ok:
        raise ProbeError(
            f"Cannot create upload session ({response.status_code}): "
            f"{response.text}"
        )

    upload_url = response.headers.get("Location")
    if not upload_url:
        raise ProbeError("Google did not return a resumable upload URL")

    with book_path.open("rb") as handle:
        response = requests.put(
            upload_url,
            headers={
                "Content-Type": mime_type,
                "Content-Length": str(size),
            },
            data=handle,
            timeout=300,
        )

    if response.status_code not in (200, 201):
        raise ProbeError(
            f"Book upload failed ({response.status_code}): {response.text}"
        )

    return response.json()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Test whether a PC using the same KOCloud OAuth client can see "
            "existing drive.file-managed KOCloud storage and upload one book."
        )
    )
    parser.add_argument(
        "--credentials",
        required=True,
        type=Path,
        help="Google OAuth client JSON already used by KOCloud",
    )
    parser.add_argument(
        "book",
        type=Path,
        help="One EPUB or PDF to upload",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    credentials_path = args.credentials.expanduser().resolve()
    book_path = args.book.expanduser().resolve()

    if not book_path.is_file():
        print(f"ERROR: Book does not exist: {book_path}", file=sys.stderr)
        return 2

    if book_path.suffix.lower() not in {".epub", ".pdf"}:
        print(
            "ERROR: For this probe, use one .epub or .pdf file.",
            file=sys.stderr,
        )
        return 2

    try:
        client_id, client_secret = load_oauth_client(credentials_path)

        print("KOCloud companion feasibility probe")
        print("------------------------------------")
        print(f"OAuth JSON : {credentials_path}")
        print(f"Book       : {book_path.name}")
        print(f"Scope      : {SCOPE}")
        print()
        print("Requesting Google Device authorization...")

        device = request_device_authorization(client_id)

        print()
        print("Open this URL in a browser:")
        print(f"  {device['verification_url']}")
        print()
        print("Enter this code:")
        print(f"  {device['user_code']}")
        print()
        print(
            "IMPORTANT: authorize with the SAME Google account used "
            "by KOCloud on the Kobo."
        )
        print()
        print("Waiting for authorization", end="", flush=True)

        access_token = poll_for_access_token(
            client_id,
            client_secret,
            device,
        )
        print(" OK")
        print()

        print("[1/3] Looking for the existing KOCloud root...")
        root = find_kocloud_root(access_token)
        print(f"      FOUND: {root['name']} ({root['id']})")

        print("[2/3] Looking for the existing KOCloud/Books folder...")
        books = find_books_folder(access_token, root["id"])
        print(f"      FOUND: {books['name']} ({books['id']})")

        print("[3/3] Uploading one test book...")
        uploaded = upload_book(
            access_token,
            book_path,
            books["id"],
        )

        print()
        print("SUCCESS")
        print("-------")
        print(f"Uploaded : {uploaded.get('name', book_path.name)}")
        print(f"File ID  : {uploaded.get('id', '?')}")
        print(f"Size     : {uploaded.get('size', '?')} bytes")
        print()
        print(
            "Now open KOCloud -> Library -> My Books on the Kobo.\n"
            "If the book appears, the companion-uploader concept is proven."
        )
        return 0

    except (ProbeError, requests.RequestException) as exc:
        print()
        print()
        print("PROBE FAILED")
        print("------------")
        print(str(exc))
        print()
        print(
            "The probe did not create KOCloud folders. "
            "If it failed before [3/3], no ebook was uploaded."
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
