#!/usr/bin/env python3
"""Complete a Nextcloud Login Flow v2 grant without a browser.

The emulator's Chrome renders the flow page blank, which has blocked every
attempt to sign an emulator into a real server. The flow does not need a
browser though — it needs a session that logs in and then posts the grant, and
that is all this does.

    python grant3.py <flow-url> <user> <password>

The flow URL is what the application asked the browser to open; read it off
the device with:

    adb -s <device> shell "dumpsys activity activities \\
        | grep -o 'https://<host>/login/v2/flow/[A-Za-z0-9._~-]*' | head -1"
"""

import base64
import http.cookiejar
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

flow, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
origin = "://".join(urllib.parse.urlparse(flow)[:2])
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
opener.addheaders = [
    ("User-Agent", "Mozilla/5.0 (Linux; Android 14) Chrome/131 Mobile Safari/537.36")
]


def fetch(url, data=None, referer=None):
    request = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    if data is not None:
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
    if referer:
        request.add_header("Referer", referer)
        request.add_header("Origin", origin)
    try:
        with opener.open(request) as response:
            return response.geturl(), response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        # The flow page answers 403 with the login page in the body while
        # nobody is signed in, which is the state this starts in.
        return error.geturl(), error.read().decode("utf-8", "replace")


def request_token(html):
    match = re.search(r'data-requesttoken="([^"]+)"', html)
    return match.group(1) if match else None


url, _ = fetch(flow)
parsed = urllib.parse.urlparse(url)
redirect = parsed.path + (f"?{parsed.query}" if parsed.query else "")
login_page, login_html = fetch(
    f"{origin}/index.php/login?redirect_url=" + urllib.parse.quote(redirect, safe="")
)
token = request_token(login_html)
if token is None:
    sys.exit("no request token on the login page")

grant_page, grant_html = fetch(
    f"{origin}/index.php/login",
    urllib.parse.urlencode(
        {
            "user": user,
            "password": password,
            "requesttoken": token,
            "redirect_url": redirect,
            "timezone": "Europe/Prague",
            "timezone_offset": "2",
        }
    ).encode(),
    referer=login_page,
)
action = re.search(r'<form[^>]*action="([^"]*login/v2/grant[^"]*)"', grant_html)
state = re.search(r'id="initial-state-core-loginFlowAuth"[^>]*value="([^"]*)"', grant_html)
if action is not None:
    # Older servers render the form; the state token rides in the action URL.
    grant_url = action.group(1).replace("&amp;", "&")
    body = {"requesttoken": request_token(grant_html) or token}
elif state is not None:
    # Newer ones draw it client-side and leave the state token in inline state.
    grant_url = f"{origin}/index.php/login/v2/grant"
    body = {
        "stateToken": json.loads(base64.b64decode(state.group(1)))["stateToken"],
        "requesttoken": request_token(grant_html) or token,
    }
else:
    sys.exit(f"no grant form and no login flow state after login; landed on {grant_page}")

final, final_html = fetch(
    grant_url, urllib.parse.urlencode(body).encode(), referer=grant_page
)
print("granted ->", final)
print("account connected:", "Account connected" in final_html or "connected" in final_html.lower())
