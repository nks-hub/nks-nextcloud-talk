#!/usr/bin/env python3
"""Rewrite a device database into the one the store screenshots are taken from.

The screenshots on a store page are read by everybody, so no real person, no
real conversation and no real server may appear in them. Editing the pictures
afterwards is not the way: it has to be redone by hand for every screen, every
language and every screen size, and one missed corner is a name published for
good.

So the DATA is anonymised instead, once, and every screenshot after that is
taken from an application that never held anything else. The input is a copy of
the database of an installed build:

    adb -s <device> exec-out "run-as com.nkshub.nextcloudtalk \\
        cat files/nks_nextcloud_talk.sqlite" > device.sqlite
    python tool/store_screenshot_data.py device.sqlite demo.sqlite --language cs
    adb -s <device> shell "run-as com.nkshub.nextcloudtalk \\
        cp /sdcard/demo.sqlite files/nks_nextcloud_talk.sqlite"

Nothing here talks to a server. The rows keep the shape the application wrote,
so no parser is asked to accept anything it would not accept from Talk itself;
only what a reader can see is replaced.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
from pathlib import Path

SERVER = "https://talk.example.com"
LOGIN = "alex"

# The people and rooms the screenshots show. Invented, and deliberately dull:
# a store page is not the place for a joke that ages.
ROOMS = {
    "en": [
        ("Note to self", 6, "Remember to send the meeting notes", 0),
        ("Product Team", 2, "Mockups are ready for review", 2),
        ("Sam Carter", 1, "Sounds good, talk tomorrow", 0),
        ("Design Review", 2, "The new icons are in the shared folder", 0),
        ("Let's get started!", 2, "Adding the team now", 0),
        ("Release planning", 2, "Friday works for everybody", 0),
    ],
    "cs": [
        ("Poznámka pro mne", 6, "Nezapomenout poslat zápis z porady", 0),
        ("Produktový tým", 2, "Návrhy jsou připravené ke kontrole", 2),
        ("Sam Carter", 1, "Dobře, zítra se ozvu", 0),
        ("Revize návrhu", 2, "Nové ikony jsou ve sdílené složce", 0),
        ("Začínáme!", 2, "Přidávám tým", 0),
        ("Plán vydání", 2, "Pátek všem vyhovuje", 0),
    ],
}

# The conversation the chat screenshot is taken in: the second room above.
CHAT = {
    "en": [
        ("Sam Carter", "Mockups are ready for review, in the shared folder."),
        ("You", "Thanks! I will go through them this afternoon."),
        ("Ada Novak", "The spacing on the second screen still looks tight."),
        ("Sam Carter", "Good catch, I will widen it before Friday."),
        ("You", "Shall we do a quick call after lunch?"),
        ("Sam Carter", "Works for me."),
    ],
    "cs": [
        ("Sam Carter", "Návrhy jsou ke kontrole ve sdílené složce."),
        ("You", "Díky! Projdu je odpoledne."),
        ("Ada Nováková", "Na druhé obrazovce jsou pořád úzké okraje."),
        ("Sam Carter", "Máš pravdu, do pátku to rozšířím."),
        ("You", "Dáme po obědě krátký hovor?"),
        ("Sam Carter", "Pro mě dobré."),
    ],
}


def busiest_account(db: sqlite3.Connection) -> str:
    rows = db.execute(
        "select account_id, count(*) from cached_conversations group by account_id"
    ).fetchall()
    if not rows:
        raise SystemExit("no cached conversations in this database")
    return max(rows, key=lambda row: row[1])[0]


def anonymise(source: Path, target: Path, language: str) -> None:
    shutil.copyfile(source, target)
    db = sqlite3.connect(target)
    db.text_factory = str
    account = busiest_account(db)

    # One account, so no second server name can appear in a corner.
    for table in (
        "accounts",
        "account_themes",
        "certificate_pins",
        "cached_conversations",
        "conversation_avatars",
        "chat_capabilities",
        "chat_scopes",
        "cached_chat_messages",
        "cached_threads",
        "text_send_operations",
        "chat_drafts",
        "attachment_runtime_accounts",
        "attachment_jobs",
        "call_sessions",
        "call_lifecycle_sessions",
    ):
        column = "id" if table == "accounts" else "account_id"
        try:
            db.execute(f"delete from {table} where {column} != ?", (account,))
        except sqlite3.OperationalError:
            continue
    db.execute(
        "update accounts set server_url = ?, login_name = ?, selected = 1"
        " where id = ?",
        (SERVER, LOGIN, account),
    )

    rooms = ROOMS[language]
    kept = db.execute(
        "select token from cached_conversations order by last_activity desc limit ?",
        (len(rooms),),
    ).fetchall()
    tokens = [row[0] for row in kept]
    db.execute(
        "delete from cached_conversations where token not in (%s)"
        % ",".join("?" * len(tokens)),
        tokens,
    )
    # A custom avatar is a real person's picture; the initials the application
    # draws instead are part of the product anyway.
    db.execute("delete from conversation_avatars")

    for token, (name, room_type, preview, unread) in zip(tokens, rooms):
        raw = json.loads(
            db.execute(
                "select raw_json from cached_conversations where token = ?",
                (token,),
            ).fetchone()[0]
        )
        raw.update(
            displayName=name,
            name=name,
            description="",
            type=room_type,
            unreadMessages=unread,
            isCustomAvatar=False,
            hasCall=False,
        )
        last = raw.get("lastMessage")
        if isinstance(last, dict):
            last.update(
                message=preview,
                messageParameters={},
                systemMessage="",
                actorDisplayName=name,
            )
        db.execute(
            "update cached_conversations set display_name = ?, room_name = ?,"
            " description = '', room_type = ?, unread_messages = ?,"
            " is_custom_avatar = 0, last_message_text = ?, peer_status = null,"
            " peer_status_message = null, raw_json = ? where token = ?",
            (name, name, room_type, unread, preview, json.dumps(raw), token),
        )

    chat_token = tokens[1] if len(tokens) > 1 else tokens[0]
    template = db.execute(
        "select raw_json from cached_chat_messages where system_message = ''"
        " and message_type = 'comment' limit 1"
    ).fetchone()
    if template is None:
        raise SystemExit("no ordinary message to take the row shape from")
    shape = json.loads(template[0])
    db.execute("delete from cached_chat_messages")
    db.execute("delete from cached_threads")

    # Late morning, so the timestamps read as a conversation from today.
    base = 1788_600_000
    for index, (author, text) in enumerate(CHAT[language]):
        mine = author == "You"
        message = dict(shape)
        message.update(
            id=900 + index,
            token=chat_token,
            actorType="users",
            actorId=LOGIN if mine else author.split()[0].lower(),
            actorDisplayName="Alex Morgan" if mine else author,
            timestamp=base + index * 180,
            systemMessage="",
            messageType="comment",
            message=text,
            messageParameters={},
            reactions={},
            referenceId="",
            threadId=None,
        )
        db.execute(
            "insert into cached_chat_messages (account_id, room_token,"
            " message_id, actor_type, actor_id, actor_display_name, timestamp,"
            " system_message, message_type, reference_id, display_text,"
            " deleted, thread_id, raw_json)"
            " values (?, ?, ?, 'users', ?, ?, ?, '', 'comment', '', ?, 0,"
            " null, ?)",
            (
                account,
                chat_token,
                message["id"],
                message["actorId"],
                message["actorDisplayName"],
                message["timestamp"],
                text,
                json.dumps(message),
            ),
        )

    db.commit()
    db.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument("--language", choices=sorted(ROOMS), default="en")
    arguments = parser.parse_args()
    anonymise(arguments.source, arguments.target, arguments.language)
    print(f"written {arguments.target} ({arguments.language})")


if __name__ == "__main__":
    main()
