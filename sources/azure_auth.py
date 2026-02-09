# Copyright (C) Microsoft Corporation.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""
DNF Plugin for Azure AD Authentication against Azure Blob Storage repositories.

This plugin intercepts DNF repository requests and adds Azure AD Bearer tokens
to authenticate against Azure Blob Storage accounts configured for Azure AD auth.

Usage:
1. Install the plugin RPM
2. Configure repos in /etc/dnf/plugins/azure_auth.conf
3. Ensure az cli is logged in (az login) or use Managed Identity on Azure VMs

For pre-generated tokens (bootstrapping scenarios):
    export DNF_PLUGIN_AZURE_AUTH_TOKEN="<your-token>"
"""

import logging
import dnf
import json
import subprocess
import os
import base64
from datetime import datetime, timezone

logger = logging.getLogger("dnf.plugin.azure_auth")

# Azure CLI command to get access token for Azure Storage
AZ_COMMAND = [
    "az",
    "account",
    "get-access-token",
    "--output",
    "json",
    "--resource",
    "https://storage.azure.com",
]


class AzureAuthConfigParser(object):
    """Config parser for azure_auth.conf

    Args:
      conf (libdnf.conf.ConfigParser): Config to parse

    The config format is:
        [repo-id]
        # Currently no per-repo options, but extensible for future use
    """

    def __init__(self, conf):
        self.conf = conf

    def parse_config(self):
        conf = self.conf
        azure_auth_map = {}
        # Skip [main] — that's the plugin enable/disable section, not a repo
        for section in conf.sections():
            if section == "main":
                continue
            azure_auth_map[section] = {}
        return azure_auth_map


class AzureAuth(dnf.Plugin):
    """DNF Plugin that adds Azure AD authentication headers to configured repos."""

    name = "azure_auth"

    def __init__(self, base, cli):
        super(AzureAuth, self).__init__(base, cli)
        self.verbose = base.conf.debuglevel >= 3

    def config(self):
        """Configure repositories with Azure AD authentication headers."""
        conf = self.read_config(self.base.conf)

        parser = AzureAuthConfigParser(conf)
        azure_auth_map = parser.parse_config()

        if self.verbose:
            _print_banner()
            if azure_auth_map:
                _print_info("Configured repo sections: {}".format(
                    ", ".join(azure_auth_map.keys())))
            else:
                _print_error("No repo sections found in /etc/dnf/plugins/azure_auth.conf")
                _print_info("  Add a section like [azure-rpm-repo] to enable Azure AD auth")
                _print_info("  The section name must match a repo ID in /etc/yum.repos.d/")

        # Reuse the token between repos to avoid multiple browser popups
        # when not `az login`ed. If cross-tenant support is added in the future,
        # this will need to change to per-tenant tokens.
        env_token = os.getenv("DNF_PLUGIN_AZURE_AUTH_TOKEN", None)
        token = env_token
        token_source = "DNF_PLUGIN_AZURE_AUTH_TOKEN env var" if env_token else None

        for key in azure_auth_map.keys():
            repo = self.base.repos.get(key, None)
            if repo and repo.enabled:
                if not token:
                    token, token_source = get_token(verbose=self.verbose)
                if token:
                    logger.debug(f"Setting Azure AD auth headers for repo: {key}")
                    if self.verbose:
                        _print_info("Applying Azure AD token to repo: {}".format(key))
                        _print_info("  Token source: {}".format(token_source))
                        _print_info("  Repo baseurl: {}".format(
                            ", ".join(repo.baseurl) if repo.baseurl else "(mirrors)"))
                        _print_token_details(token)
                    repo.set_http_headers(
                        [
                            "x-ms-version: 2022-11-02",
                            "Authorization: Bearer {}".format(token),
                        ]
                    )
                    if self.verbose:
                        _print_info("  Headers set: Authorization: Bearer <token>, x-ms-version: 2022-11-02")
                else:
                    logger.warning(f"Failed to get Azure AD token for repo: {key}")
                    if self.verbose:
                        _print_error("FAILED to get Azure AD token for repo: {}".format(key))
            elif self.verbose and repo:
                _print_info("Skipping disabled repo: {}".format(key))

        if self.verbose:
            _print_separator()


def get_token(verbose=False):
    """Get Azure AD access token for Azure Storage.

    Uses az cli to get a token. If running under sudo, attempts to use
    the original user's az login session via runuser.

    Returns:
        tuple: (access_token, source_description) or (None, None)
    """
    # If SUDO_USER is set, run az as that account using runuser,
    # to avoid users having to be both `az login`ed and `sudo az login`ed
    if "SUDO_USER" in os.environ:
        cmd = ["runuser", "-u", os.environ["SUDO_USER"], "--"] + AZ_COMMAND
        source = "az cli (via runuser as {})".format(os.environ["SUDO_USER"])
    else:
        cmd = AZ_COMMAND
        source = "az cli (direct)"

    if verbose:
        _print_info("Acquiring token...")
        _print_info("  Command: {}".format(" ".join(cmd)))
        if "SUDO_USER" in os.environ:
            _print_info("  Running as SUDO_USER: {}".format(os.environ["SUDO_USER"]))

    try:
        output = subprocess.run(
            cmd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        token_data = json.loads(output.stdout)
        if verbose:
            _print_info("  Token acquired successfully")
            _print_info("  Subscription: {}".format(token_data.get("subscription", "N/A")))
            _print_info("  Tenant: {}".format(token_data.get("tenant", "N/A")))
            _print_info("  Token type: {}".format(token_data.get("tokenType", "N/A")))
            _print_info("  Expires on: {}".format(token_data.get("expiresOn", "N/A")))
        return token_data["accessToken"], source
    except subprocess.CalledProcessError as e:
        if verbose:
            _print_error("az cli failed (exit code {}): {}".format(
                e.returncode, e.stderr.decode().strip() if e.stderr else "no stderr"))
        # Upon an error if running as sudo, try again without runuser in case
        # our user has permission on the storage account but the sudo user doesn't.
        if "SUDO_USER" in os.environ:
            if verbose:
                _print_info("  Retrying without runuser (direct az cli)...")
            try:
                output = subprocess.run(
                    AZ_COMMAND,
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                token_data = json.loads(output.stdout)
                if verbose:
                    _print_info("  Token acquired via direct az cli (fallback)")
                return token_data["accessToken"], "az cli (direct fallback)"
            except subprocess.CalledProcessError:
                logger.error("Failed to get Azure AD token via az cli")
                return None, None
        else:
            logger.error(f"Failed to get Azure AD token: {e}")
            return None, None
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse az cli output: {e}")
        return None, None
    except FileNotFoundError:
        logger.error("az cli not found. Please install azure-cli package.")
        if verbose:
            _print_error("az cli binary not found in PATH")
        return None, None


# ─── POC Verbose Output Helpers ───────────────────────────────────────────────

def _print_banner():
    """Print a visible banner when verbose mode is active."""
    print("")
    print("=" * 70)
    print("  Azure AD Auth Plugin (POC Verbose Mode)")
    print("=" * 70)


def _print_separator():
    print("=" * 70)
    print("")


def _print_info(msg):
    print("  [azure-auth] {}".format(msg))


def _print_error(msg):
    print("  [azure-auth] ERROR: {}".format(msg))


def _print_token_details(token):
    """Decode and display JWT token claims for debugging."""
    try:
        # JWT format: header.payload.signature
        parts = token.split(".")
        if len(parts) != 3:
            _print_info("  Token format: not a standard JWT")
            return

        # Decode payload (add padding if needed)
        payload = parts[1]
        padding = 4 - len(payload) % 4
        if padding != 4:
            payload += "=" * padding

        claims = json.loads(base64.b64decode(payload))

        _print_info("  ── JWT Token Claims ──")
        _print_info("  Token (first 40 chars): {}...".format(token[:40]))

        # Identity info
        _print_info("  App ID (client):  {}".format(claims.get("appid", "N/A")))
        _print_info("  Object ID (oid):  {}".format(claims.get("oid", "N/A")))
        _print_info("  Tenant ID (tid):  {}".format(claims.get("tid", "N/A")))

        # Identity type
        idtyp = claims.get("idtyp", None)
        xms_mirid = claims.get("xms_mirid", None)
        if xms_mirid:
            _print_info("  Identity type:    Managed Identity")
            _print_info("  MI Resource ID:   {}".format(xms_mirid))
        elif idtyp:
            _print_info("  Identity type:    {}".format(idtyp))
        else:
            upn = claims.get("upn", claims.get("unique_name", None))
            if upn:
                _print_info("  Identity type:    User ({})".format(upn))
            else:
                _print_info("  Identity type:    Service Principal / App")

        # Audience and scope
        _print_info("  Audience (aud):   {}".format(claims.get("aud", "N/A")))

        # Timestamps
        iat = claims.get("iat")
        exp = claims.get("exp")
        if iat:
            issued = datetime.fromtimestamp(iat, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
            _print_info("  Issued at:        {}".format(issued))
        if exp:
            expires = datetime.fromtimestamp(exp, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
            now = datetime.now(timezone.utc).timestamp()
            remaining_min = int((exp - now) / 60)
            _print_info("  Expires at:       {} ({} min remaining)".format(expires, remaining_min))

        _print_info("  ─────────────────────")

    except Exception as e:
        _print_info("  Token decode failed: {} (token will still be used)".format(e))
