#!/usr/bin/env python3
"""
Host-side parser for NDM browser-bridge download messages.

Spec: reverse/specs/07_BROWSER_PROTOCOL.md
Wire format is produced by BetterNDM / original extension and consumed by
NeatWebSocketServer on the Mac host.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional


# Endpoint constants (host server)
WS_HOST = "127.0.0.1"
WS_PORT = 10007
WS_PATH = "/download"
WS_SUBPROTOCOL = "neatextension.v1"
WS_URL = f"ws://{WS_HOST}:{WS_PORT}{WS_PATH}"

# Host → extension control frames
HOST_MSG_WAITING = "waiting"
HOST_MSG_NOWAITING = "nowaiting"
HOST_MSG_SHOW_PANEL_CHROME_ON = "ShowPanelChrome=1"
HOST_MSG_SHOW_PANEL_CHROME_OFF = "ShowPanelChrome=0"
HOST_MSG_SHOW_PANEL_FOX_ON = "ShowPanelFox=1"
HOST_MSG_SHOW_PANEL_FOX_OFF = "ShowPanelFox=0"
HOST_MSG_SHOW_PANEL_EDGE_ON = "ShowPanelEdge=1"
HOST_MSG_SHOW_PANEL_EDGE_OFF = "ShowPanelEdge=0"

# Extension → host numeric field keys
FIELD_METHOD = "1"
FIELD_URL = "2"
FIELD_FILENAME = "3"
FIELD_PAGE_TITLE = "4"
FIELD_PAGE_URL = "5"
FIELD_LTYPE = "6"
FIELD_FILE_SIZE = "7"
FIELD_CONTENT_TYPE = "8"
FIELD_USER_AGENT = "9"
FIELD_REQ_CONTENT_TYPE = "10"
FIELD_CONTENT_DISPOSITION = "11"
POST_DATA_KEY = "__0NeatPostData9__"

MAX_MESSAGE_BYTES = 118784


@dataclass
class HostDownloadMessage:
    method: str = "GET"
    url: str = ""
    filename: str = ""
    page_title: str = ""
    page_url: str = ""
    ltype: str = "normal"
    file_size: int = 0
    content_type: str = ""
    user_agent: str = ""
    req_content_type: str = ""
    content_disposition: str = ""
    origin: str = ""
    referer: str = ""
    cookies: str = ""
    post_data: Optional[str] = None
    extra_headers: Dict[str, str] = field(default_factory=dict)

    def to_request_headers(self) -> List[str]:
        """Headers the engine should attach (Name: value lines)."""
        headers: List[str] = []
        if self.origin:
            headers.append(f"Origin: {self.origin}")
        if self.referer:
            headers.append(f"Referer: {self.referer}")
        if self.cookies:
            headers.append(f"Cookie: {self.cookies}")
        if self.req_content_type:
            headers.append(f"Content-Type: {self.req_content_type}")
        if self.content_disposition:
            headers.append(f"Content-Disposition: {self.content_disposition}")
        for k, v in self.extra_headers.items():
            headers.append(f"{k}: {v}")
        return headers


def parse_extension_message(raw: str) -> HostDownloadMessage:
    """
    Parse extension→host text frame into HostDownloadMessage.

    Lines are separated by \\r\\n. Keys are either a single digit/number prefix
    before ':' (e.g. '2:https://...') or a header name (e.g. 'Cookie: ...').
    POST body may follow __0NeatPostData9__: without requiring trailing CRLF.
    """
    if len(raw.encode("utf-8", errors="replace")) > MAX_MESSAGE_BYTES:
        raise ValueError("message exceeds MAX_MESSAGE_BYTES")

    msg = HostDownloadMessage()
    # Special POST body key may embed remaining payload
    post_marker = POST_DATA_KEY + ":"
    post_idx = raw.find(post_marker)
    body = raw
    if post_idx >= 0:
        msg.post_data = raw[post_idx + len(post_marker) :]
        body = raw[:post_idx]

    for line in body.split("\r\n"):
        if not line:
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip() if not value.startswith(" ") else value[1:].rstrip("\r")
        # BetterNDM uses "Key: value" with space after colon for headers;
        # numeric keys also "1:GET"
        if value.startswith(" "):
            value = value[1:]

        if key == FIELD_METHOD:
            msg.method = value
        elif key == FIELD_URL:
            msg.url = value
        elif key == FIELD_FILENAME:
            msg.filename = value
        elif key == FIELD_PAGE_TITLE:
            msg.page_title = value
        elif key == FIELD_PAGE_URL:
            msg.page_url = value
        elif key == FIELD_LTYPE:
            msg.ltype = value or "normal"
        elif key == FIELD_FILE_SIZE:
            try:
                msg.file_size = int(value) if value else 0
            except ValueError:
                msg.file_size = 0
        elif key == FIELD_CONTENT_TYPE:
            msg.content_type = value
        elif key == FIELD_USER_AGENT:
            msg.user_agent = value
        elif key == FIELD_REQ_CONTENT_TYPE or key.lower() == "content-type":
            if key == FIELD_REQ_CONTENT_TYPE:
                msg.req_content_type = value
            else:
                msg.req_content_type = msg.req_content_type or value
        elif key == FIELD_CONTENT_DISPOSITION or key.lower() == "content-disposition":
            msg.content_disposition = value
        elif key.lower() == "origin":
            msg.origin = value
        elif key.lower() == "referer":
            msg.referer = value
        elif key.lower() == "cookie":
            msg.cookies = value
        elif key.lower().startswith("x-"):
            msg.extra_headers[key] = value
        else:
            # keep unknown as extra header if looks like one
            if key and not key.isdigit():
                msg.extra_headers[key] = value

    if not msg.url:
        raise ValueError("missing required field 2 (url)")
    return msg


def build_extension_message(
    *,
    method: str = "GET",
    url: str,
    ltype: str = "normal",
    page_title: str = "",
    page_url: str = "",
    origin: str = "",
    referer: str = "",
    cookies: str = "",
    file_size: int = 0,
    content_type: str = "",
    filename: str = "",
) -> str:
    """Build a wire message matching BetterNDM's sendToNDM shape (for tests)."""
    lines = [
        f"{FIELD_METHOD}:{method}",
        f"{FIELD_URL}:{url}",
        f"{FIELD_LTYPE}:{ltype}",
    ]
    if filename:
        lines.append(f"{FIELD_FILENAME}:{filename}")
    if page_title:
        lines.append(f"{FIELD_PAGE_TITLE}:{page_title}")
    if origin:
        lines.append(f"Origin: {origin}")
    if referer:
        lines.append(f"Referer: {referer}")
    if page_url:
        lines.append(f"{FIELD_PAGE_URL}:{page_url}")
    if cookies:
        lines.append(f"Cookie: {cookies}")
    if file_size:
        lines.append(f"{FIELD_FILE_SIZE}:{file_size}")
    if content_type:
        lines.append(f"{FIELD_CONTENT_TYPE}:{content_type}")
    return "\r\n".join(lines) + "\r\n"


if __name__ == "__main__":
    sample = build_extension_message(
        url="https://example.com/a.zip",
        page_title="Example",
        origin="https://example.com",
        referer="https://example.com/page",
        file_size=100,
        content_type="application/zip",
    )
    parsed = parse_extension_message(sample)
    print(parsed)
    print("WS_URL", WS_URL, WS_SUBPROTOCOL)
