# ==============================================================================
# Sample RPM Spec File for POC Testing
# ==============================================================================
# This spec file creates a simple test package that can be used to validate
# the Azure Blob Storage RPM repository setup.
# 
# Build with: rpmbuild -bb hello-azure.spec
# ==============================================================================

Name:           hello-azure
Version:        1.0.0
Release:        1%{?dist}
Summary:        Test package for Azure Blob Storage RPM Repository

License:        MIT
URL:            https://github.com/example/hello-azure

BuildArch:      noarch

%description
A simple test package that demonstrates successful installation from
an Azure Blob Storage-backed RPM repository.

This package installs:
- A hello-azure command-line tool
- Documentation files

%install
# Create binary directory
mkdir -p %{buildroot}%{_bindir}

# Create the main script
cat > %{buildroot}%{_bindir}/hello-azure << 'SCRIPT'
#!/bin/bash
# hello-azure - Test script for Azure Blob Storage RPM Repository

VERSION="1.0.0"

print_banner() {
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         Azure Blob Storage RPM Repository - Test Package      ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
}

print_info() {
    echo ""
    echo "Package Information:"
    echo "  Name:        hello-azure"
    echo "  Version:     $VERSION"
    echo "  Source:      Azure Blob Storage RPM Repository"
    echo ""
    echo "System Information:"
    echo "  Hostname:    $(hostname)"
    echo "  OS:          $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
    echo "  Kernel:      $(uname -r)"
    echo "  Date:        $(date)"
    echo ""
}

case "$1" in
    --version|-v)
        echo "hello-azure version $VERSION"
        ;;
    --help|-h)
        echo "Usage: hello-azure [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --version, -v    Show version information"
        echo "  --help, -h       Show this help message"
        echo ""
        echo "With no options, displays a welcome message and system info."
        ;;
    *)
        print_banner
        print_info
        echo "✓ Package installation successful!"
        echo "  Your Azure Blob Storage RPM repository is working correctly."
        echo ""
        ;;
esac
SCRIPT

chmod +x %{buildroot}%{_bindir}/hello-azure

# Create documentation directory
mkdir -p %{buildroot}%{_docdir}/%{name}

# Create README
cat > %{buildroot}%{_docdir}/%{name}/README.md << 'README'
# hello-azure

A test package for validating Azure Blob Storage RPM repository functionality.

## Usage

```bash
# Display welcome message and system info
hello-azure

# Show version
hello-azure --version

# Show help
hello-azure --help
```

## About

This package was created as part of a Proof of Concept (POC) for using
Azure Blob Storage as an RPM repository backend. If you can install and
run this package, your repository setup is working correctly!

## Repository Setup

This package was installed from an Azure Blob Storage container configured
as a YUM/DNF repository. The setup typically involves:

1. Creating an Azure Storage Account
2. Creating a Blob Container
3. Uploading RPM packages and repository metadata
4. Configuring Azure AD RBAC roles (Storage Blob Data Reader)
5. Installing dnf-plugin-azure-auth on clients for automatic token injection

For more information, see the implementation guide in the POC repository.
README

# Create LICENSE
cat > %{buildroot}%{_docdir}/%{name}/LICENSE << 'LICENSE'
MIT License

Copyright (c) 2024 RPM Repository POC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICENSE

%files
%{_bindir}/hello-azure
%doc %{_docdir}/%{name}/README.md
%license %{_docdir}/%{name}/LICENSE

%changelog
* %(date "+%a %b %d %Y") POC Developer <poc@example.com> - 1.0.0-1
- Initial release for Azure Blob Storage RPM Repository POC
- Added hello-azure command-line tool
- Added documentation and license files
