#!/usr/bin/env python3
"""Bootstrap Google Drive OAuth credentials for KOCloud.

This script is intended to run once on a desktop computer. It performs the
Google OAuth 2.0 authorization-code flow with a loopback redirect and PKCE,
then prints the long-lived configuration values KOCloud needs on KOReader.

It uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import secrets
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path
from typing import Any

AUTHORIZATION_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
DRIVE_SCOPE = "https://www.googleapis.com/auth/drive"


class OAuthCallbackServer(http.server.HTTPServer):
    """HTTP server that stores one OAuth callback result."""

    authorization_code: str | None = None
    authorization_error: str | None = None
    returned_state: str | None = None


class OAuthCallbackHandler(http.server.BaseHTTPRequestHandler):
    """Handle the loopback redirect from Google's OAuth server."""

    server: OAuthCallbackServer

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        self.server.authorization_code = _first(query.get("code"))
        self.server.authorization_error = _first(query.get("error"))
        self.server.returned_state = _first(query.get("state"))

        if self.server.authorization_error:
            title = "KOCloud authorization failed"
            message = (
                "Google authorization was not completed. "
                "You can close this browser tab."
            )
            status = 400
        else:
            title = "KOCloud authorization complete"
            message = (
                "Authorization was received successfully. "
                "You can close this browser tab and return to the terminal."
            )
            status = 200

        body = (
            "<!doctype html>"
            "<html><head><meta charset='utf-8'>"
            f"<title>{title}</title></head>"
            "<body>"
            f"<h2>{title}</h2>"
            f"<p>{message}</p>"
            "</body></html>"
        ).encode("utf-8")

        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *args: object) -> None:
        """Suppress the default HTTP request log."""
        return


def _first(values: list[str] | None) -> str | None:
    """Return the first query-string value when available."""
    if not values:
        return None
    return values[0]


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description=(
            "Authorize KOCloud for full Google Drive access and obtain "
            "a refresh token."
        )
    )
    parser.add_argument(
        "credentials",
        type=Path,
        help="Google Desktop OAuth client JSON downloaded from Google Cloud.",
    )
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="Do not open a browser automatically; print the URL instead.",
    )
    return parser.parse_args()


def load_desktop_client(path: Path) -> tuple[str, str | None]:
    """Load a Google Desktop OAuth client JSON file.

    Args:
        path: Path to the downloaded client-secret JSON file.

    Returns:
        A tuple containing client_id and optional client_secret.

    Raises:
        ValueError: If the file is not a Desktop/installed OAuth client or
            required fields are missing.
    """
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"Unable to read credentials file: {exc}") from exc

    installed = raw.get("installed")
    if not isinstance(installed, dict):
        raise ValueError(
            "Expected a Google Desktop OAuth client JSON containing "
            'an "installed" object.'
        )

    client_id = installed.get("client_id")
    client_secret = installed.get("client_secret")

    if not isinstance(client_id, str) or not client_id:
        raise ValueError("Desktop OAuth credentials do not contain client_id.")

    if not isinstance(client_secret, str) or not client_secret:
        client_secret = None

    return client_id, client_secret


def create_pkce_pair() -> tuple[str, str]:
    """Create a PKCE code verifier and S256 challenge."""
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


def build_authorization_url(
    *,
    client_id: str,
    redirect_uri: str,
    state: str,
    code_challenge: str,
) -> str:
    """Build the Google OAuth authorization URL."""
    params = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": DRIVE_SCOPE,
        "access_type": "offline",
        "prompt": "consent",
        "include_granted_scopes": "true",
        "state": state,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
    }
    return AUTHORIZATION_ENDPOINT + "?" + urllib.parse.urlencode(params)


def exchange_code(
    *,
    client_id: str,
    client_secret: str | None,
    authorization_code: str,
    redirect_uri: str,
    code_verifier: str,
) -> dict[str, Any]:
    """Exchange an authorization code for Google OAuth tokens."""
    fields = {
        "client_id": client_id,
        "code": authorization_code,
        "code_verifier": code_verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    }

    if client_secret:
        fields["client_secret"] = client_secret

    request = urllib.request.Request(
        TOKEN_ENDPOINT,
        data=urllib.parse.urlencode(fields).encode("ascii"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"Google token exchange failed with HTTP {exc.code}: {details}"
        ) from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Unable to reach Google token endpoint: {exc}") from exc

    try:
        result = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Google returned an invalid token response.") from exc

    if not isinstance(result, dict):
        raise RuntimeError("Google returned an unexpected token response.")

    return result


def print_kocloud_config(
    *,
    client_id: str,
    client_secret: str | None,
    refresh_token: str,
) -> None:
    """Print the Google Drive provider configuration needed by KOCloud."""
    config: dict[str, str] = {
        "client_id": client_id,
        "refresh_token": refresh_token,
    }

    if client_secret:
        config["client_secret"] = client_secret

    print("\nAuthorization successful.\n")
    print("KOCloud Google Drive provider configuration:")
    print(json.dumps(config, indent=2))
    print(
        "\nKeep the refresh token private. "
        "Do not commit this output to Git."
    )


def main() -> int:
    """Run the desktop OAuth bootstrap flow."""
    args = parse_args()

    try:
        client_id, client_secret = load_desktop_client(args.credentials)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    code_verifier, code_challenge = create_pkce_pair()
    state = secrets.token_urlsafe(32)

    server = OAuthCallbackServer(
        ("127.0.0.1", 0),
        OAuthCallbackHandler,
    )
    port = server.server_address[1]
    redirect_uri = f"http://127.0.0.1:{port}/"

    authorization_url = build_authorization_url(
        client_id=client_id,
        redirect_uri=redirect_uri,
        state=state,
        code_challenge=code_challenge,
    )

    print("Opening Google authorization in your browser.")
    print("If the browser does not open, visit this URL:\n")
    print(authorization_url)
    print()

    if not args.no_browser:
        webbrowser.open(authorization_url)

    worker = threading.Thread(target=server.handle_request, daemon=True)
    worker.start()
    worker.join()
    server.server_close()

    if server.authorization_error:
        print(
            f"ERROR: Google authorization failed: "
            f"{server.authorization_error}",
            file=sys.stderr,
        )
        return 1

    if server.returned_state != state:
        print(
            "ERROR: OAuth state mismatch. Authorization result was rejected.",
            file=sys.stderr,
        )
        return 1

    authorization_code = server.authorization_code
    if not authorization_code:
        print(
            "ERROR: Google did not return an authorization code.",
            file=sys.stderr,
        )
        return 1

    try:
        tokens = exchange_code(
            client_id=client_id,
            client_secret=client_secret,
            authorization_code=authorization_code,
            redirect_uri=redirect_uri,
            code_verifier=code_verifier,
        )
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    refresh_token = tokens.get("refresh_token")
    if not isinstance(refresh_token, str) or not refresh_token:
        print(
            "ERROR: Google did not return a refresh token. "
            "Re-run the flow with consent, or revoke the existing grant "
            "and authorize again.",
            file=sys.stderr,
        )
        return 1

    granted_scope = tokens.get("scope")
    if isinstance(granted_scope, str) and DRIVE_SCOPE not in granted_scope.split():
        print(
            "ERROR: Full Google Drive scope was not granted.",
            file=sys.stderr,
        )
        return 1

    print_kocloud_config(
        client_id=client_id,
        client_secret=client_secret,
        refresh_token=refresh_token,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
