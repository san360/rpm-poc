#!/bin/bash
# ==============================================================================
# Docker Build and Upload Script for RPM Repository
# ==============================================================================
# This script is designed to run inside the rpm-builder Docker container.
# It builds test RPMs, creates repository metadata, and optionally uploads
# to Azure Blob Storage.
# ==============================================================================

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  RPM Repository Builder and Uploader${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"

# Configuration
REPO_PATH="/workspace/repo"
SPECS_PATH="/workspace/specs"

# ==============================================================================
# Step 1: Build Test RPM Packages
# ==============================================================================
echo ""
echo -e "${GREEN}Step 1: Building Test RPM Packages${NC}"

# Create multiple test packages for variety
packages=(
    "test-alpha:1.0.0:Test Alpha Package"
    "test-beta:2.0.0:Test Beta Package"
    "test-gamma:0.5.0:Test Gamma Package (pre-release)"
)

for pkg_info in "${packages[@]}"; do
    IFS=':' read -r name version summary <<< "$pkg_info"
    
    echo "  Building $name-$version..."
    
    cat > ~/rpmbuild/SPECS/${name}.spec << EOF
Name:           ${name}
Version:        ${version}
Release:        1%{?dist}
Summary:        ${summary}

License:        MIT
URL:            https://example.com/${name}

%description
${summary}
This package is part of the Azure Blob Storage RPM Repository POC.

%install
mkdir -p %{buildroot}%{_bindir}
cat > %{buildroot}%{_bindir}/${name} << 'SCRIPT'
#!/bin/bash
echo "═══════════════════════════════════════════════════════"
echo "  ${name} v${version}"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  Installed from: Azure Blob Storage RPM Repository"
echo "  Package:        ${name}"
echo "  Version:        ${version}"
echo "  Build Date:     $(date)"
echo ""
SCRIPT
chmod +x %{buildroot}%{_bindir}/${name}

mkdir -p %{buildroot}%{_docdir}/${name}
echo "${summary} - Version ${version}" > %{buildroot}%{_docdir}/${name}/README
echo "" >> %{buildroot}%{_docdir}/${name}/README
echo "This package is part of the Azure Blob Storage RPM Repository POC." >> %{buildroot}%{_docdir}/${name}/README

%files
%{_bindir}/${name}
%doc %{_docdir}/${name}/README

%changelog
* $(date "+%a %b %d %Y") POC Builder <poc@example.com> - ${version}-1
- Built for Azure Blob Storage POC testing
EOF

    rpmbuild -bb ~/rpmbuild/SPECS/${name}.spec 2>&1 | grep -E "(Wrote:|error:)" || true
done

echo ""
echo "  Collecting built RPMs..."
mkdir -p $REPO_PATH/Packages
find ~/rpmbuild/RPMS -name "*.rpm" -exec cp -v {} $REPO_PATH/Packages/ \;

echo ""
echo "  Built packages:"
ls -la $REPO_PATH/Packages/

# ==============================================================================
# Step 2: Create Repository Metadata
# ==============================================================================
echo ""
echo -e "${GREEN}Step 2: Creating Repository Metadata${NC}"

createrepo_c $REPO_PATH

echo "  Metadata files:"
ls -la $REPO_PATH/repodata/

# ==============================================================================
# Step 3: Upload to Azure Blob Storage (if configured)
# ==============================================================================
echo ""
if [ -n "$STORAGE_ACCOUNT" ]; then
    echo -e "${GREEN}Step 3: Uploading to Azure Blob Storage${NC}"
    
    # Check Azure login
    if ! az account show &>/dev/null; then
        echo -e "${YELLOW}  Warning: Not logged in to Azure CLI${NC}"
        echo "  Skipping upload. Please ensure Azure credentials are mounted."
    else
        CONTAINER=${CONTAINER_NAME:-yumrepo}
        
        echo "  Storage Account: $STORAGE_ACCOUNT"
        echo "  Container: $CONTAINER"
        echo ""
        
        # Upload all files
        az storage blob upload-batch \
            --account-name "$STORAGE_ACCOUNT" \
            --destination "$CONTAINER" \
            --source "$REPO_PATH" \
            --auth-mode login \
            --overwrite
        
        echo ""
        echo -e "${GREEN}  Upload complete!${NC}"
        
        # List uploaded files
        echo ""
        echo "  Uploaded files:"
        az storage blob list \
            --account-name "$STORAGE_ACCOUNT" \
            --container-name "$CONTAINER" \
            --auth-mode login \
            --output table 2>/dev/null | head -20
    fi
else
    echo -e "${YELLOW}Step 3: Skipping Azure Upload (STORAGE_ACCOUNT not set)${NC}"
    echo "  To upload to Azure, set the STORAGE_ACCOUNT environment variable."
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Build Summary${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Repository Location: $REPO_PATH"
echo ""
echo "Packages Built:"
find $REPO_PATH/Packages -name "*.rpm" -exec basename {} \;
echo ""
echo "Repository Files:"
tree $REPO_PATH 2>/dev/null || find $REPO_PATH -type f
echo ""
echo -e "${GREEN}Done!${NC}"
