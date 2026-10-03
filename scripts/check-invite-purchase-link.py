#!/usr/bin/env python3
"""Resolve the public invite purchase link before each macOS build. No login."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import re
import urllib.parse
import urllib.request

PRODUCT = "https://www.aigoodbro.com/products/codex-invite-points"
FALLBACK = "https://aigoodbro.com"
HOSTS = {"aigoodbro.com", "www.aigoodbro.com"}


def permitted(url):
    value = urllib.parse.urlparse(url)
    return value.scheme == "https" and value.hostname in HOSTS and value.port in (None, 443) and not value.username


class SameSiteRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        if not permitted(url):
            raise ValueError("Unexpected redirect host")
        return super().redirect_request(request, response, code, message, headers, url)


def usable(status, url, content_type, body):
    if not (200 <= status < 300 and permitted(url) and "text/html" in content_type.lower()):
        return False
    path = urllib.parse.urlparse(url).path.rstrip("/")
    if path != "/products/codex-invite-points":
        return False
    text = body.decode("utf-8", errors="replace")
    headings = " ".join(re.findall(r"<(?:title|h1)[^>]*>(.*?)</(?:title|h1)>", text, re.S | re.I))
    return bool(text.strip()) and not re.search(r"\b404\b|not found|页面不存在|商品不存在", headings, re.I)


def check():
    receipt = {"checkedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(), "requestedURL": PRODUCT}
    try:
        request = urllib.request.Request(PRODUCT, headers={"User-Agent": "AiGoodBro-LinkCheck/1.0", "Accept": "text/html"})
        with urllib.request.build_opener(SameSiteRedirect()).open(request, timeout=12) as response:
            body = response.read(262144)
            ok = usable(response.status, response.geturl(), response.headers.get("Content-Type", ""), body)
            receipt.update(status=response.status, finalURL=response.geturl(), productAvailable=ok)
    except Exception as error:
        receipt.update(productAvailable=False, errorType=type(error).__name__)
    receipt["selectedURL"] = PRODUCT if receipt["productAvailable"] else FALLBACK
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plist", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    # Validate the target before making a network request or changing anything.
    with args.plist.open("rb") as source:
        values = plistlib.load(source)
    result = check()
    values["AiGoodBroInvitePurchaseURL"] = result["selectedURL"]
    temporary = args.plist.with_name(args.plist.name + ".invite-link.tmp")
    with temporary.open("wb") as output:
        plistlib.dump(values, output, sort_keys=False)
    temporary.replace(args.plist)
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(result, indent=2) + "\n")
    print("Invite purchase link: " + result["selectedURL"])


if __name__ == "__main__":
    main()
