# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the GPLv2 License.

Summary:        DNF plugin for accessing repos in Azure Blob Storage via Azure AD
Name:           dnf-plugin-azure-auth
Version:        0.1.0
Release:        1%{?dist}
License:        GPLv2
Vendor:         Microsoft Corporation
Group:          Applications/Tools
URL:            https://github.com/Metaswitch/dnf-plugin-azure-auth
Source0:        azure_auth.py
Source1:        azure_auth.conf
%global debug_package %{nil}
Requires:       python3-dnf
Requires:       azure-cli
# No BuildRequires needed - just copying Python files
BuildArch:      noarch

%description
DNF plugin for accessing repos in Azure Blob Storage via Azure AD authentication.

This plugin allows dnf/yum to authenticate against Azure Blob Storage repositories
using Azure AD tokens instead of SAS tokens or public access.

Features:
- Uses Azure CLI (az account get-access-token) for authentication
- Supports Managed Identity on Azure VMs
- Supports pre-generated tokens via DNF_PLUGIN_AZURE_AUTH_TOKEN environment variable
- Compatible with RHEL 8/9, Azure Linux, and other dnf-based distributions

%prep
# No prep needed - sources are standalone files

%install
# Use /usr/lib/python3/dist-packages for Debian compatibility
# On RHEL, dnf-plugins are typically in /usr/lib/python3.x/site-packages/dnf-plugins/
mkdir -p %{buildroot}/usr/lib/python3/dist-packages/dnf-plugins/
mkdir -p %{buildroot}%{_sysconfdir}/dnf/plugins/
cp %{SOURCE0} %{buildroot}/usr/lib/python3/dist-packages/dnf-plugins/
cp %{SOURCE1} %{buildroot}%{_sysconfdir}/dnf/plugins/azure_auth.conf

%files
%defattr(-,root,root)
%config(noreplace) %{_sysconfdir}/dnf/plugins/azure_auth.conf
/usr/lib/python3/dist-packages/dnf-plugins/azure_auth.py

%changelog
* Fri Jan 31 2026 RPM POC <rpm-poc@example.com> - 0.1.0-1
- Initial package for RPM repository POC
- Based on Metaswitch/dnf-plugin-azure-auth