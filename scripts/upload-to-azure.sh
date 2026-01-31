#!/bin/bash
#===============================================================================
# Upload RPMs to Azure Blob Storage using Azure AD Authentication
# Uploads RPM packages and creates/updates repository metadata
#===============================================================================

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PACKAGES_DIR="$PROJECT_ROOT/packages"

# Load environment variables
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
elif [[ -f "$PROJECT_ROOT/.env.generated" ]]; then
    source "$PROJECT_ROOT/.env.generated"
fi

# Configuration
AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
AZURE_STORAGE_CONTAINER="${AZURE_STORAGE_CONTAINER:-rpm-repo}"
REPO_PATH="${REPO_PATH:-el9/x86_64}"
LOCAL_PACKAGES_DIR="${LOCAL_PACKAGES_DIR:-$PACKAGES_DIR}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Uploads RPM packages to Azure Blob Storage using Azure AD authentication.

Options:
  --storage-account, -s   Azure storage account name
  --container, -c         Blob container name (default: rpm-repo)
  --repo-path, -r         Repository path in container (default: el9/x86_64)
  --packages-dir, -p      Local directory containing RPMs (default: packages/)
  --help, -h              Show this help message

Environment Variables:
  AZURE_STORAGE_ACCOUNT   Storage account name
  AZURE_STORAGE_CONTAINER Container name
  REPO_PATH               Repository path (e.g., el8/x86_64 or el9/x86_64)

Prerequisites:
  - Azure CLI installed and logged in (az login)
  - Storage Blob Data Contributor role on the storage account

Examples:
  # Using command line arguments
  $0 -s rpmrepopoc12345 -r el9/x86_64

  # Using environment variables
  export AZURE_STORAGE_ACCOUNT=rpmrepopoc12345
  $0

  # Upload to multiple paths
  $0 -s rpmrepopoc12345 -r el8/x86_64
  $0 -s rpmrepopoc12345 -r el9/x86_64

EOF
    exit 0
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --storage-account|-s)
                AZURE_STORAGE_ACCOUNT="$2"
                shift 2
                ;;
            --container|-c)
                AZURE_STORAGE_CONTAINER="$2"
                shift 2
                ;;
            --repo-path|-r)
                REPO_PATH="$2"
                shift 2
                ;;
            --packages-dir|-p)
                LOCAL_PACKAGES_DIR="$2"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

# Validate configuration
validate_config() {
    if [[ -z "$AZURE_STORAGE_ACCOUNT" ]]; then
        log_error "Missing required configuration: AZURE_STORAGE_ACCOUNT"
        echo ""
        echo "Set via environment variable or --storage-account argument"
        exit 1
    fi

    # Verify Azure AD login
    log_info "Verifying Azure AD authentication..."
    if ! az account show &>/dev/null; then
        log_error "Not logged in to Azure. Run 'az login' first."
        exit 1
    fi

    log_success "Azure AD authentication verified"
}

# Upload single file to Azure Blob using Azure AD
upload_file() {
    local local_file="$1"
    local blob_path="$2"
    local content_type="${3:-application/octet-stream}"

    az storage blob upload \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --container-name "$AZURE_STORAGE_CONTAINER" \
        --name "$blob_path" \
        --file "$local_file" \
        --content-type "$content_type" \
        --auth-mode login \
        --overwrite \
        --only-show-errors
}

# Upload RPM packages
upload_packages() {
    log_info "Uploading RPM packages from: $LOCAL_PACKAGES_DIR"

    if [[ ! -d "$LOCAL_PACKAGES_DIR" ]]; then
        log_error "Packages directory not found: $LOCAL_PACKAGES_DIR"
        exit 1
    fi

    local rpm_count=0
    for rpm_file in "$LOCAL_PACKAGES_DIR"/*.rpm; do
        if [[ -f "$rpm_file" ]]; then
            local filename=$(basename "$rpm_file")
            # Upload RPMs to the root of REPO_PATH (alongside repodata)
            # This matches where createrepo expects them (location href="package.rpm")
            local blob_path="${REPO_PATH}/${filename}"
            
            log_info "Uploading: $filename -> $blob_path"
            upload_file "$rpm_file" "$blob_path" "application/x-rpm"
            
            rpm_count=$((rpm_count + 1))
        fi
    done

    if [[ $rpm_count -eq 0 ]]; then
        log_warning "No RPM files found in $LOCAL_PACKAGES_DIR"
        return 1
    fi

    log_success "Uploaded $rpm_count RPM package(s)"
}

# Create and upload repository metadata
update_repository() {
    log_info "Updating repository metadata..."

    local repodata_dir="$LOCAL_PACKAGES_DIR/repodata"

    # Check if local repodata exists, if not create it
    if [[ ! -d "$repodata_dir" ]]; then
        log_info "Creating local repository metadata..."
        if command -v createrepo_c &> /dev/null; then
            createrepo_c "$LOCAL_PACKAGES_DIR"
        elif command -v createrepo &> /dev/null; then
            createrepo "$LOCAL_PACKAGES_DIR"
        else
            log_error "createrepo_c or createrepo not found"
            return 1
        fi
    fi

    # Upload repodata files
    for file in "$repodata_dir"/*; do
        if [[ -f "$file" ]]; then
            local filename=$(basename "$file")
            local blob_path="${REPO_PATH}/repodata/${filename}"
            local content_type="application/octet-stream"

            case "$filename" in
                *.xml|*.xml.gz)
                    content_type="application/xml"
                    ;;
                *.sqlite*)
                    content_type="application/x-sqlite3"
                    ;;
            esac

            log_info "Uploading: $filename"
            upload_file "$file" "$blob_path" "$content_type"
        fi
    done

    log_success "Repository metadata updated"
}

# Show repository information
show_repo_info() {
    echo ""
    echo "=============================================="
    echo "Repository Information"
    echo "=============================================="
    echo "Base URL: https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/${REPO_PATH}"
    echo ""
    echo "Client Setup:"
    echo "1. Install dnf-plugin-azure-auth and azure-cli"
    echo "2. Login: az login (or az login --identity on Azure VMs)"
    echo "3. Add to /etc/dnf/plugins/azure_auth.conf:"
    echo "   [azure-rpm-repo]"
    echo ""
    echo "4. Create /etc/yum.repos.d/azure-rpm.repo:"
    echo "   [azure-rpm-repo]"
    echo "   name=Azure RPM Repository"
    echo "   baseurl=https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/${REPO_PATH}"
    echo "   enabled=1"
    echo "   gpgcheck=0"
    echo ""
}

# Main function
main() {
    echo ""
    echo "=============================================="
    echo "Azure Blob RPM Repository Upload (Azure AD)"
    echo "=============================================="
    echo ""

    parse_args "$@"
    validate_config
    upload_packages
    update_repository
    show_repo_info

    log_success "Upload complete!"
}

main "$@"
