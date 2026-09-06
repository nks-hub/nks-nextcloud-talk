#!/usr/bin/env python3
"""A Talk server that exists only so the store screenshots can be taken.

A screenshot of a chat client has to show conversations, and conversations are
the one thing that must never be real: a store page is read by everybody. The
sibling tool `store_screenshot_data.py` rewrites the database instead, but a
database alone is not enough — the application synchronises when a screen
opens, the invented server does not answer, and every picture then carries a
red "Offline" banner over an empty conversation.

So the invented server is served. This answers the handful of OCS endpoints the
conversation list and a chat room read, with the same invented people the data
tool uses, and nothing else: no writes, no login flow, no signalling.

    python tool/store_screenshot_server.py --language cs --port 8443

The device reaches it over `adb reverse`, and the certificate is pinned in the
database rather than trusted by the system, which is how the application
already lets a user accept a self-signed server:

    adb -s <device> reverse tcp:443 tcp:8443
    # server_url = https://talk.localtest.me  (a public name for 127.0.0.1)
    # certificate_pins = the fingerprint this prints on start

Nothing here is part of the application. It is a screenshot rig, and it lives
in `tool/` next to the other things that are run by hand.

A second, unrelated use added later: automated call coverage. The same rig
also answers the INTERNAL Talk signalling endpoints — settings, the room
session activation, and the long-poll pull/push a client uses to negotiate a
call — so a Dart test can drive the real network code (`CallTransportService`,
`HttpNextcloudApi`, `CallSignalingCoordinator`) against a real socket instead
of `MockClient`. Nothing there is faked WebRTC media; the endpoints under
`/_test/` exist only so a test can inject a "peer" message or read back what
the app pushed, and are not part of what a real Talk server answers.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import http.server
import json
import ssl
import tempfile
import time
import urllib.parse
from pathlib import Path

HOST_NAME = "talk.localtest.me"
USER = "alex"
DISPLAY_NAME = "Alex Morgan"

ROOMS = {
    "en": [
        ("Product Team", 2, "Mockups are ready for review", 2, True),
        ("Note to self", 6, "Remember to send the meeting notes", 0, False),
        ("Sam Carter", 1, "Sounds good, talk tomorrow", 0, False),
        ("Design Review", 2, "The new icons are in the shared folder", 0, False),
        ("Release planning", 2, "Friday works for everybody", 0, False),
        ("Support", 2, "I will take a look and let you know", 0, False),
    ],
    "cs": [
        ("Produktový tým", 2, "Návrhy jsou připravené ke kontrole", 2, True),
        ("Poznámka pro mne", 6, "Nezapomenout poslat zápis z porady", 0, False),
        ("Sam Carter", 1, "Dobře, zítra se ozvu", 0, False),
        ("Revize návrhu", 2, "Nové ikony jsou ve sdílené složce", 0, False),
        ("Plán vydání", 2, "Pátek všem vyhovuje", 0, False),
        ("Podpora", 2, "Kouknu na to a dám vědět", 0, False),
    ],
}

CHAT = {
    "en": [
        ("sam", "Sam Carter", "Mockups are ready for review, in the shared folder."),
        (USER, DISPLAY_NAME, "Thanks! I will go through them this afternoon."),
        ("ada", "Ada Novak", "The spacing on the second screen still looks tight."),
        ("sam", "Sam Carter", "Good catch, I will widen it before Friday."),
        (USER, DISPLAY_NAME, "Shall we do a quick call after lunch?"),
        ("sam", "Sam Carter", "Works for me."),
    ],
    "cs": [
        ("sam", "Sam Carter", "Návrhy jsou ke kontrole ve sdílené složce."),
        (USER, DISPLAY_NAME, "Díky! Projdu je odpoledne."),
        ("ada", "Ada Nováková", "Na druhé obrazovce jsou pořád úzké okraje."),
        ("sam", "Sam Carter", "Máš pravdu, do pátku to rozšířím."),
        (USER, DISPLAY_NAME, "Dáme po obědě krátký hovor?"),
        ("sam", "Sam Carter", "Pro mě dobré."),
    ],
}

# Only what this rig answers for. A capability the application does not find
# simply switches a control off, which is what an old server would do too.
TALK_FEATURES = [
    "archived-conversations-v2",
    "audio",
    "avatar",
    "chat-get-context",
    "chat-read-marker",
    "chat-read-status",
    "chat-reference-id",
    "chat-replies",
    "chat-unread",
    "chat-v2",
    "conversation-v4",
    "delete-messages",
    "edit-messages",
    "favorites",
    "last-room-activity",
    "markdown-messages",
    "media-caption",
    "mention-flag",
    "note-to-self",
    "reactions",
    "read-only-rooms",
    "rich-object-sharing",
    "room-description",
    "silent-send",
    "system-messages",
    "threads",
    "unified-search",
    "video",
    "voice-message-sharing",
]

TOKEN_PREFIX = "demoroom"

# Login Flow v2 tokens. Opaque to the application, 32 characters or more, and
# the two must differ; nothing about them is secret, since the rig hands the
# credentials to whoever asks.
POLL_TOKEN = "screenshotrigpolltoken0000000000000000"
LOGIN_TOKEN = "screenshotrigflowtoken0000000000000000"
APP_PASSWORD = "screenshot-rig-app-password"

# Relative to the moment the rig starts, so a screenshot never shows a list of
# conversations that all happened on the same day last year. The first two
# rooms are hours old and show a time; the rest are days old and show a date.
BASE_TIME = int(time.time())
ROOM_AGE_SECONDS = (3600, 3 * 3600, 26 * 3600, 50 * 3600, 74 * 3600, 98 * 3600)


def token_of(index: int) -> str:
    return f"{TOKEN_PREFIX}{index}"


def room_index(token: str) -> int:
    tail = token.removeprefix(TOKEN_PREFIX)
    return int(tail) if tail.isdigit() else 0


def ocs(data: object, status: int = 200) -> bytes:
    return json.dumps(
        {
            "ocs": {
                "meta": {"status": "ok", "statuscode": status, "message": "OK"},
                "data": data,
            }
        }
    ).encode("utf-8")


def room_json(index: int, language: str) -> dict:
    name, room_type, preview, unread, favorite = ROOMS[language][index]
    if index == 0:
        preview = CHAT[language][-1][2]
    token = token_of(index)
    activity = BASE_TIME - ROOM_AGE_SECONDS[index % len(ROOM_AGE_SECONDS)]
    return {
        "id": 100 + index,
        "token": token,
        "type": room_type,
        "name": name,
        "displayName": name,
        "description": "",
        "participantType": 1,
        "attendeeId": 200 + index,
        "attendeePin": None,
        "attributes": 0,
        "hasScheduledMessages": 0,
        "hiddenPinnedId": 0,
        "lastPinnedId": 0,
        "liveTranscriptionLanguageId": "",
        "tagIds": [],
        "actorType": "users",
        "actorId": USER,
        "permissions": 254,
        "attendeePermissions": 0,
        "callPermissions": 0,
        "defaultPermissions": 0,
        "participantFlags": 0,
        "readOnly": 0,
        "listable": 0,
        "messageExpiration": 0,
        "lastPing": 0,
        "sessionId": "0",
        "hasPassword": False,
        "hasCall": False,
        "callFlag": 0,
        "canStartCall": True,
        "canDeleteConversation": True,
        "canLeaveConversation": True,
        "lastActivity": activity,
        "isFavorite": favorite,
        "notificationLevel": 0,
        "notificationCalls": 1,
        "lobbyState": 0,
        "lobbyTimer": 0,
        "sipEnabled": 0,
        "canEnableSIP": False,
        "unreadMessages": unread,
        "unreadMention": False,
        "unreadMentionDirect": False,
        "lastReadMessage": newest_id(index),
        "lastCommonReadMessage": newest_id(index),
        "lastMessage": {
            "id": newest_id(index),
            "token": token,
            "actorType": "users",
            "actorId": "sam",
            "actorDisplayName": name,
            "timestamp": activity,
            "systemMessage": "",
            "messageType": "comment",
            "isReplyable": True,
            "referenceId": "",
            "message": preview,
            "messageParameters": {},
            "reactions": {},
            "expirationTimestamp": 0,
            "markdown": True,
        },
        "objectType": "",
        "objectId": "",
        "breakoutRoomMode": 0,
        "breakoutRoomStatus": 0,
        "avatarVersion": "",
        "isCustomAvatar": False,
        "callStartTime": 0,
        "callRecording": 0,
        "recordingConsent": 0,
        "mentionPermissions": 0,
        "isArchived": False,
        "isImportant": False,
        "isSensitive": False,
    }


def newest_id(index: int) -> int:
    """The id of a room's last message.

    A history fetch is anchored at what the room list said the last message
    was, and the server may only answer with messages at or before it. Ids that
    run past the anchor are refused — which is what "the latest chat response
    was rejected" means when it appears over an empty conversation.
    """
    return 900 + index * 10


def chat_json(token: str, language: str) -> list[dict]:
    index = room_index(token)
    first = newest_id(index) - len(CHAT[language]) + 1
    messages = []
    for index, (actor, display, text) in enumerate(CHAT[language]):
        messages.append(
            {
                "id": first + index,
                "token": token,
                "actorType": "users",
                "actorId": actor,
                "actorDisplayName": display,
                "timestamp": BASE_TIME - 3600 - (len(CHAT[language]) - index) * 240,
                "systemMessage": "",
                "messageType": "comment",
                "isReplyable": True,
                "referenceId": "",
                "message": text,
                "messageParameters": {},
                "reactions": {},
                "expirationTimestamp": 0,
                "markdown": True,
            }
        )
    return list(reversed(messages))


def participants(language: str) -> list[dict]:
    """Who is in the room the chat screenshot is taken in."""
    people = [(USER, DISPLAY_NAME, 1)]
    seen: set[str] = {USER}
    for actor, display, _ in CHAT[language]:
        if actor not in seen:
            seen.add(actor)
            people.append((actor, display, 3))
    return [
        {
            "attendeeId": 300 + index,
            "actorType": "users",
            "actorId": actor,
            "displayName": display,
            "participantType": participant_type,
            "lastPing": BASE_TIME - 60,
            "sessionIds": [],
            "permissions": 254,
            "attendeePermissions": 0,
            "inCall": 0,
            "status": None,
            "statusIcon": None,
            "statusMessage": None,
        }
        for index, (actor, display, participant_type) in enumerate(people)
    ]


def capabilities() -> dict:
    return {
        "version": {
            "major": 34,
            "minor": 0,
            "micro": 1,
            "string": "34.0.1",
            "edition": "",
            "extendedSupport": False,
        },
        "capabilities": {
            "core": {"pollinterval": 60, "webdav-root": "remote.php/webdav"},
            "spreed": {
                "features": TALK_FEATURES,
                "features-local": [],
                "config": {
                    "attachments": {
                        "allowed": True,
                        "folder": "/Talk",
                        "conversation-subfolders": True,
                    },
                    "chat": {"max-length": 32000, "read-privacy": 0},
                    "conversations": {"can-create": True},
                },
                "config-local": {},
                "version": "22.0.0",
            },
        },
    }


def signaling_settings() -> dict:
    """Internal-mode signalling settings: no external HPB, no relay."""
    return {
        "signalingMode": "internal",
        "userId": USER,
        "hideWarning": True,
        "server": "",
        "federation": None,
        "stunservers": [],
        "turnservers": [],
        "sipDialinInfo": "",
    }


def call_room_json(token: str, session_id: str) -> dict:
    """A `participants/active` response for a synthetic call room.

    Same field set as [room_json], which the real app already parses
    successfully for the conversation list; only the identity and session
    differ, since a call test opens a room the screenshot rig does not know.
    """
    return {
        "id": 900,
        "token": token,
        "type": 2,
        "name": "Automated call",
        "displayName": "Automated call",
        "description": "",
        "participantType": 1,
        "attendeeId": 900,
        "attendeePin": None,
        "attributes": 0,
        "hasScheduledMessages": 0,
        "hiddenPinnedId": 0,
        "lastPinnedId": 0,
        "liveTranscriptionLanguageId": "",
        "tagIds": [],
        "actorType": "users",
        "actorId": USER,
        "permissions": 254,
        "attendeePermissions": 0,
        "callPermissions": 0,
        "defaultPermissions": 0,
        "participantFlags": 0,
        "readOnly": 0,
        "listable": 0,
        "messageExpiration": 0,
        "lastPing": 0,
        "sessionId": session_id,
        "hasPassword": False,
        "hasCall": True,
        "callFlag": 0,
        "canStartCall": True,
        "canDeleteConversation": True,
        "canLeaveConversation": True,
        "lastActivity": BASE_TIME,
        "isFavorite": False,
        "notificationLevel": 0,
        "notificationCalls": 1,
        "lobbyState": 0,
        "lobbyTimer": 0,
        "sipEnabled": 0,
        "canEnableSIP": False,
        "unreadMessages": 0,
        "unreadMention": False,
        "unreadMentionDirect": False,
        "lastReadMessage": 0,
        "lastCommonReadMessage": 0,
        "lastMessage": None,
        "objectType": "",
        "objectId": "",
        "breakoutRoomMode": 0,
        "breakoutRoomStatus": 0,
        "avatarVersion": "",
        "isCustomAvatar": False,
        "callStartTime": BASE_TIME,
        "callRecording": 0,
        "recordingConsent": 0,
        "mentionPermissions": 0,
        "isArchived": False,
        "isImportant": False,
        "isSensitive": False,
    }


class CallState:
    """Everything the internal-signalling test endpoints keep between
    requests: one call, one account, no persistence, reset between tests."""

    def __init__(self) -> None:
        self.session_counter = 0
        self.peer_joined = False
        self.pushed: list[dict] = []
        self.queued: list[dict] = []

    def reset(self) -> None:
        self.__init__()  # noqa: PLC2801 — deliberately re-runs __init__


CALL_STATE = CallState()


class Handler(http.server.BaseHTTPRequestHandler):
    language = "en"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        # The query too: what a history fetch asks for is the difference
        # between an answer the application takes and one it rejects.
        print(f"  {self.path}")

    def _send(
        self,
        body: bytes,
        content_type: str = "application/json",
        last_given: int | None = None,
    ) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # The room list is only accepted with the cursor-v4 headers; the chat
        # endpoint with the two of its own. Sending them everywhere is
        # harmless and keeps the handler in one piece.
        self.send_header("X-Nextcloud-Talk-Hash", "screenshotrig1")
        self.send_header("X-Nextcloud-Talk-Modified-Before", str(BASE_TIME))
        given = str(last_given if last_given is not None else newest_id(0))
        self.send_header("X-Chat-Last-Given", given)
        self.send_header("X-Chat-Last-Common-Read", given)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        language = Handler.language
        if path.endswith("/cloud/capabilities"):
            return self._send(ocs(capabilities()))
        if path.endswith("/status.php"):
            return self._send(
                json.dumps(
                    {
                        "installed": True,
                        "maintenance": False,
                        "needsDbUpgrade": False,
                        "version": "34.0.1.2",
                        "versionstring": "34.0.1",
                        "edition": "",
                        "productname": "Nextcloud",
                    }
                ).encode()
            )
        if path.endswith("/apps/spreed/api/v4/room"):
            return self._send(
                ocs([room_json(index, language) for index in range(len(ROOMS[language]))])
            )
        if path.endswith("/participants"):
            return self._send(ocs(participants(language)))
        if "/apps/spreed/api/v1/chat/" in path:
            token = path.split("/apps/spreed/api/v1/chat/")[1].split("/")[0]
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if query.get("lookIntoFuture", ["0"])[0] == "1":
                # Nothing ever arrives, so the long poll answers "no change".
                self.send_response(304)
                self.end_headers()
                return
            messages = chat_json(token, language)
            # For a history page `X-Chat-Last-Given` is the OLDEST message
            # given, not the newest: it is where the next page continues, and
            # a header past the oldest id is refused as a page that claims
            # more than it delivered.
            return self._send(
                ocs(messages),
                last_given=min(message["id"] for message in messages),
            )
        if path.endswith("/apps/spreed/api/v3/signaling/settings"):
            return self._send(ocs(signaling_settings()))
        if "/apps/spreed/api/v3/signaling/" in path:
            # The internal long poll: any message the test queued, exactly
            # once, in the order it was queued, THEN this side's own session
            # plus — once the test says a peer joined — that peer. The
            # `usersInRoom` item must be last: the real protocol codec
            # rejects a `message` item once it has seen `usersInRoom`.
            items = [
                {"type": "message", "data": json.dumps(message)}
                for message in CALL_STATE.queued
            ]
            CALL_STATE.queued.clear()
            items.append(
                {
                    "type": "usersInRoom",
                    "data": self._signaling_users(),
                }
            )
            return self._send(ocs(items))
        if path == "/_test/pushed":
            return self._send(json.dumps(CALL_STATE.pushed).encode())
        # Everything else — avatars, user status, search — is answered as
        # missing. The application draws initials and hides what it cannot ask
        # for, which is what a smaller server would give it anyway.
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _signaling_users(self) -> list[dict]:
        users = [
            {
                "sessionId": str(CALL_STATE.session_counter or 1),
                "roomId": 900,
                "lastPing": int(time.time()),
                "userId": USER,
                "inCall": 7,
                "participantPermissions": 254,
                "actorType": "users",
                "actorId": USER,
            }
        ]
        if CALL_STATE.peer_joined:
            users.append(
                {
                    "sessionId": "peer-session-1",
                    "roomId": 900,
                    "lastPing": int(time.time()),
                    "userId": "peer",
                    "inCall": 7,
                    "participantPermissions": 254,
                    "actorType": "users",
                    "actorId": "peer",
                }
            )
        return users

    def _read_json_body(self) -> object:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_POST(self) -> None:  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        # Login Flow v2, so a device with no account can be given one without
        # a browser: the rig answers the poll immediately instead of waiting
        # for a grant nobody can click on an emulator.
        if path.endswith("/login/v2"):
            return self._send(
                json.dumps(
                    {
                        "poll": {
                            "token": POLL_TOKEN,
                            "endpoint": f"https://{HOST_NAME}"
                            "/index.php/login/v2/poll",
                        },
                        "login": f"https://{HOST_NAME}"
                        f"/index.php/login/v2/flow/{LOGIN_TOKEN}",
                    }
                ).encode()
            )
        if path.endswith("/login/v2/poll"):
            return self._send(
                json.dumps(
                    {
                        "server": f"https://{HOST_NAME}",
                        "loginName": USER,
                        "appPassword": APP_PASSWORD,
                    }
                ).encode()
            )
        if path.endswith("/participants/active"):
            token = path.split("/room/")[1].split("/")[0]
            CALL_STATE.session_counter += 1
            return self._send(
                ocs(call_room_json(token, str(CALL_STATE.session_counter)))
            )
        if "/apps/spreed/api/v3/signaling/" in path:
            # The internal batch push: `messages` is a JSON array of
            # `{ev, fn, sessionId}`, `fn` itself a JSON-encoded message. Only
            # `fn` is kept — it is what the test wants to assert on.
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8")
            form = urllib.parse.parse_qs(body)
            envelopes = json.loads(form.get("messages", ["[]"])[0])
            for envelope in envelopes:
                CALL_STATE.pushed.append(json.loads(envelope["fn"]))
            return self._send(ocs([]))
        if path == "/_test/peer-joined":
            self._read_json_body()
            CALL_STATE.peer_joined = True
            return self._send(b"{}")
        if path == "/_test/inject":
            CALL_STATE.queued.append(self._read_json_body())
            return self._send(b"{}")
        if path == "/_test/reset":
            CALL_STATE.reset()
            return self._send(b"{}")
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self) -> None:  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path.endswith("/participants/active"):
            return self._send(ocs(None))
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


def certificate(directory: Path) -> tuple[Path, str]:
    """A self-signed certificate for [HOST_NAME] and the pin that matches it.

    Kept if the directory already holds one. The pin lives in the device's
    database, so a certificate that changed on every start would mean
    re-pinning before every screenshot — and a rejected handshake looks exactly
    like a server that is not running.
    """
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "screenshot-server.pem"
    if path.exists():
        existing = x509.load_pem_x509_certificate(path.read_bytes())
        der = existing.public_bytes(serialization.Encoding.DER)
        return path, hashlib.sha256(der).hexdigest().lower()

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, HOST_NAME)])
    now = dt.datetime.now(dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=365))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName(HOST_NAME)]), critical=False
        )
        .sign(key, hashes.SHA256())
    )
    path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        )
        + cert.public_bytes(serialization.Encoding.PEM)
    )
    der = cert.public_bytes(serialization.Encoding.DER)
    return path, hashlib.sha256(der).hexdigest().lower()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--language", choices=sorted(ROOMS), default="en")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--certificate-dir", type=Path, default=None)
    arguments = parser.parse_args()

    Handler.language = arguments.language
    directory = arguments.certificate_dir or Path(tempfile.mkdtemp())
    pem, pin = certificate(directory)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(pem)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    bound_port = server.socket.getsockname()[1]
    print(
        f"https://{HOST_NAME} on 127.0.0.1:{bound_port} ({arguments.language})",
        flush=True,
    )
    print(f"pin {pin}", flush=True)
    # Machine-readable, for a test that spawned this with --port 0: the two
    # lines above are for a human running the screenshot rig by hand.
    print(f"PORT {bound_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
