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
        # Config format is extensible to support per-repo options,
        # though there are none currently
        for section in conf.sections():
            azure_auth_map[section] = {}
        return azure_auth_map


class AzureAuth(dnf.Plugin):
    """DNF Plugin that adds Azure AD authentication headers to configured repos."""

    name = "azure_auth"

    def __init__(self, base, cli):
        super(AzureAuth, self).__init__(base, cli)

    def config(self):
        """Configure repositories with Azure AD authentication headers."""
        conf = self.read_config(self.base.conf)

        parser = AzureAuthConfigParser(conf)
        azure_auth_map = parser.parse_config()

        # Reuse the token between repos to avoid multiple browser popups
        # when not `az login`ed. If cross-tenant support is added in the future,
        # this will need to change to per-tenant tokens.
        token = os.getenv("DNF_PLUGIN_AZURE_AUTH_TOKEN", None)
        
        for key in azure_auth_map.keys():
            repo = self.base.repos.get(key, None)
            if repo and repo.enabled:
                if not token:
                    token = get_token()
                if token:
                    logger.debug(f"Setting Azure AD auth headers for repo: {key}")
                    repo.set_http_headers(
                        [
                            "x-ms-version: 2022-11-02",
                            "Authorization: Bearer {}".format(token),
                        ]
                    )
                else:
                    logger.warning(f"Failed to get Azure AD token for repo: {key}")


def get_token():
    """Get Azure AD access token for Azure Storage.
    
    Uses az cli to get a token. If running under sudo, attempts to use
    the original user's az login session via runuser.
    
    Returns:
        str: The access token, or None if unable to get token
    """
    # If SUDO_USER is set, run az as that account using runuser,
    # to avoid users having to be both `az login`ed and `sudo az login`ed
    if "SUDO_USER" in os.environ:
        cmd = ["runuser", "-u", os.environ["SUDO_USER"], "--"] + AZ_COMMAND
    else:
        cmd = AZ_COMMAND

    try:
        output = subprocess.run(
            cmd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return json.loads(output.stdout)["accessToken"]
    except subprocess.CalledProcessError as e:
        # Upon an error if running as sudo, try again without runuser in case
        # our user has permission on the storage account but the sudo user doesn't.
        if "SUDO_USER" in os.environ:
            try:
                output = subprocess.run(
                    AZ_COMMAND,
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                return json.loads(output.stdout)["accessToken"]
            except subprocess.CalledProcessError:
                logger.error("Failed to get Azure AD token via az cli")
                return None
        else:
            logger.error(f"Failed to get Azure AD token: {e}")
            return None
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse az cli output: {e}")
        return None
    except FileNotFoundError:
        logger.error("az cli not found. Please install azure-cli package.")
        return None
