#!/usr/bin/env python3
"""
Extracts a signed-in user's *currently applied* Chrome (user-scope) cloud
policy without needing to open chrome://policy and manually export it.

WHY THIS EXISTS
---------------
mosh-upol.sh (the user policy editor) needs to know a user's currently
applied managed policy (ManagedBookmarks, OpenNetworkConfiguration,
WebAppInstallForceList, ExtensionInstallForcelist, etc.) so those values can
be preserved when it points Chrome at Modmium's fake_dmserver. Up to now the
only way to get that data was: sign in, open chrome://policy, click
"Export to JSON", save it to Downloads. If an org has locked down access to
chrome://policy (or to chrome:// pages generally), that path doesn't work.

HOW THIS WORKS INSTEAD
-----------------------
The data chrome://policy renders is a signed protobuf blob
(PolicyFetchResponse -> PolicyData -> a proto holding the actual settings)
that session_manager caches locally. devpol.py (Modmium's *device* policy
editor) already reads this style of blob straight off disk for device
policy (/var/lib/devicesettings/policy.*). This script does the equivalent
for *user* policy, then reshapes the result into the exact same
{"policyValues": {"chrome": {"policies": {...}}}} JSON shape chrome://
policy's own "Export to JSON" button produces - so policy_dump_converter.py
and everything downstream of it need zero changes.

CONFIDENCE NOTE - please read before relying on this in the field
-------------------------------------------------------------------
- The protobuf parsing (PolicyFetchResponse -> PolicyData ->
  ChromeSettingsProto) is verified against the proto definitions already
  vendored in this directory and is not a guess.
- The two ways this script tries to *locate* the raw blob (a per-user
  session_manager daemon-store file, and a session_manager D-Bus call) are
  based on documented ChromeOS platform internals, but were NOT exercised
  against a real device while writing this (no ChromeOS hardware was
  available). If neither works on a given ChromeOS version, this script
  fails loudly with exactly what it tried, rather than silently producing
  nothing, so it's obvious what needs adjusting.
- The existing chrome://policy export path in mosh-upol.sh (grabpolicy) is
  left completely untouched as a fallback if this doesn't work for you.
"""
import argparse
import glob
import json
import logging
import subprocess
import sys

POLICY_TEST_TOOL_PATH = "/usr/share/.policy-test-tool"
sys.path.insert(0, POLICY_TEST_TOOL_PATH)

import device_management_backend_pb2 as dm
import chrome_settings_pb2 as cs
from google.protobuf import json_format

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

# Chromium's dm_protocol::kChromeUserPolicyType constant.
USER_POLICY_TYPE = "google/chromeos/user"

# session_manager keeps a per-daemon "daemon store" directory under each
# logged-in user's cryptohome at /home/root/<hash>/<daemon>/, used to persist
# state across reboots without it living in the unencrypted /home/user
# mount. These are the candidate filenames for its cached user policy blob.
CANDIDATE_GLOBS = [
    "/home/root/*/session_manager/policy/policy",
    "/home/root/*/session_manager/policy/policy.0",
    "/home/root/*/session_manager/policy/policy.1",
]


def _try_parse(raw: bytes, email: str):
    """Attempt to parse raw bytes as a PolicyFetchResponse belonging to
    `email`. Returns the decoded ChromeSettingsProto on success, else None."""
    try:
        resp = dm.PolicyFetchResponse()
        resp.ParseFromString(raw)
        pd = dm.PolicyData()
        pd.ParseFromString(resp.policy_data)
    except Exception:
        return None
    if pd.policy_type != USER_POLICY_TYPE:
        return None
    if email and pd.username and pd.username.lower() != email.lower():
        return None
    settings = cs.ChromeSettingsProto()
    try:
        settings.ParseFromString(pd.policy_value)
    except Exception:
        return None
    return settings


def find_via_disk(email: str):
    for pattern in CANDIDATE_GLOBS:
        for path in glob.glob(pattern):
            try:
                with open(path, "rb") as f:
                    raw = f.read()
            except OSError:
                continue
            settings = _try_parse(raw, email)
            if settings is not None:
                logging.info(f"Found user policy blob on disk: {path}")
                return settings
    return None


def _parse_dbus_bytes(dbus_stdout: str):
    """dbus-send prints byte arrays as whitespace-separated 0xNN tokens."""
    hex_bytes = [tok for tok in dbus_stdout.split() if tok.startswith("0x")]
    if not hex_bytes:
        return None
    try:
        return bytes(int(b, 16) for b in hex_bytes)
    except ValueError:
        return None


def find_via_dbus(email: str):
    """Fall back to asking session_manager directly over D-Bus - the same
    interface Chrome itself uses to fetch this data for chrome://policy."""
    try:
        result = subprocess.run(
            [
                "dbus-send", "--system", "--print-reply", "--type=method_call",
                "--dest=org.chromium.SessionManager",
                "/org/chromium/SessionManager",
                "org.chromium.SessionManagerInterface.RetrievePolicyForUser",
                f"string:{email}",
            ],
            capture_output=True, text=True, timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        logging.warning(f"dbus-send unavailable or timed out: {e}")
        return None
    if result.returncode != 0:
        logging.warning(f"session_manager D-Bus call failed: {result.stderr.strip()}")
        return None
    raw = _parse_dbus_bytes(result.stdout)
    if raw is None:
        return None
    return _try_parse(raw, email)


def _unstringify_int64(value):
    """protobuf's JSON mapping always renders int64/uint64 fields as
    strings (JS can't represent them precisely), but blob_generator.py's
    apply_user_policies() assigns values straight into protobuf fields via
    plain setattr() rather than json_format.ParseDict() - which requires a
    real Python int, not "1". Undo the stringification wherever it's
    unambiguous (a bare integer literal) so round-tripping back through
    apply_user_policies() doesn't raise a TypeError."""
    if isinstance(value, str) and value.lstrip("-").isdigit():
        return int(value)
    return value


def settings_to_policy_dump(settings) -> dict:
    """Reshape a decoded ChromeSettingsProto into the same
    {"policyValues": {"chrome": {"policies": {...}}, "extensions": {}}}
    shape chrome://policy's "Export to JSON" button produces, so
    policy_dump_converter.py needs no changes at all."""
    as_dict = json_format.MessageToDict(settings)
    policies = {}
    for name, wrapper in as_dict.items():
        # Every field on ChromeSettingsProto is itself a wrapper message
        # (e.g. ManagedBookmarksProto) carrying a field of the same name
        # as the policy itself - matching the per-policy shape
        # chrome://policy's export already uses, just keyed "value" there.
        if isinstance(wrapper, dict) and name in wrapper:
            policies[name] = {
                "value": _unstringify_int64(wrapper[name]),
                "scope": "user",
            }
    return {
        "policyValues": {
            "chrome": {"policies": policies},
            # Per-extension managed configuration is a separate policy
            # domain/fetch that this script doesn't cover - only
            # chrome-domain user policy is. If you rely on that, you'll
            # still need the chrome://policy export for now.
            "extensions": {},
        }
    }


def main():
    parser = argparse.ArgumentParser(
        description="Extract a signed-in user's current Chrome policy "
        "without chrome://policy, by reading session_manager's cached "
        "policy blob directly (on-disk, falling back to D-Bus).")
    parser.add_argument(
        "--email", required=True,
        help="Target account email (must already be signed in at least "
        "once so its policy is cached locally).")
    parser.add_argument(
        "--output", default="/root/policy.json",
        help="Where to write the resulting policy.json (default: "
        "/root/policy.json, matching what mosh-upol.sh expects).")
    args = parser.parse_args()

    settings = find_via_disk(args.email)
    if settings is None:
        logging.info("No usable on-disk policy blob found, trying D-Bus...")
        settings = find_via_dbus(args.email)

    if settings is None:
        logging.critical(
            "Could not locate this user's cached policy on-disk or via "
            "D-Bus on this ChromeOS version. Falling back to the "
            "chrome://policy export is still your best bet for now."
        )
        sys.exit(1)

    dump = settings_to_policy_dump(settings)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(dump, f, indent=2)
    logging.info(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
