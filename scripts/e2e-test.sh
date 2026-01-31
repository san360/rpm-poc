#!/bin/bash
#===============================================================================
# End-to-End Test for Azure Blob RPM Repository (Azure AD Authentication)
# Tests the complete workflow from build to deployment
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

# Load environment variables
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
elif [[ -f "$PROJECT_ROOT/.env.generated" ]]; then
    source "$PROJECT_ROOT/.env.generated"
fi

# Configuration
AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
AZURE_STORAGE_CONTAINER="${AZURE_STORAGE_CONTAINER:-rpm-repo}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
REPO_PATH="${REPO_PATH:-el9/x86_64}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Run end-to-end tests for Azure Blob RPM repository with Azure AD authentication.

Options:
  --storage-account, -s   Azure storage account name
  --resource-group, -g    Azure resource group
  --container, -c         Blob container name (default: rpm-repo)
  --repo-path, -r         Repository path (default: el9/x86_64)
  --skip-build            Skip RPM build step
  --skip-storage          Skip storage account creation (use existing)
  --cleanup               Clean up test resources after completion
  --help, -h              Show this help message

Environment Variables:
  AZURE_STORAGE_ACCOUNT   Storage account name
  AZURE_RESOURCE_GROUP    Resource group name
  AZURE_STORAGE_CONTAINER Container name
  REPO_PATH               Repository path

Examples:
  # Full end-to-end test
  $0 -g rg-rpm-test

  # Use existing storage, skip build
  $0 -s rpmrepopoc12345 --skip-build --skip-storage

EOF
    exit 0
}

SKIP_BUILD=false
SKIP_STORAGE=false
CLEANUP=false

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --storage-account|-s)
                AZURE_STORAGE_ACCOUNT="$2"
                shift 2
                ;;
            --resource-group|-g)
                AZURE_RESOURCE_GROUP="$2"
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
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-storage)
                SKIP_STORAGE=true
                shift
                ;;
            --cleanup)
                CLEANUP=true
                shift
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

# Verify Azure login
verify_azure_login() {
    log_info "Verifying Azure AD authentication..."
    if ! az account show &>/dev/null; then
        log_error "Not logged in to Azure. Run 'az login' first."
        exit 1
    fi
    
    local account_name
    account_name=$(az account show --query name -o tsv)
    log_success "Logged in to Azure: $account_name"
}

# Step 1: Build RPM packages
step_build_packages() {
    echo ""
    echo "=============================================="
    echo "Step 1: Build RPM Packages"
    echo "=============================================="

    if $SKIP_BUILD; then
        log_info "Skipping build step (--skip-build)"
        return 0
    fi

    if [[ -x "$SCRIPT_DIR/build-rpm-local.sh" ]]; then
        log_info "Building RPM packages..."
        "$SCRIPT_DIR/build-rpm-local.sh"
        log_success "RPM packages built successfully"
    else
        log_error "Build script not found: $SCRIPT_DIR/build-rpm-local.sh"
        return 1
    fi
}

# Step 2: Create/verify Azure storage
step_setup_storage() {
    echo ""
    echo "=============================================="
    echo "Step 2: Setup Azure Storage"
    echo "=============================================="

    if $SKIP_STORAGE; then
        log_info "Skipping storage setup (--skip-storage)"
        
        if [[ -z "$AZURE_STORAGE_ACCOUNT" ]]; then
            log_error "Storage account required when using --skip-storage"
            exit 1
        fi
        
        log_info "Using existing storage account: $AZURE_STORAGE_ACCOUNT"
        return 0
    fi

    if [[ -z "$AZURE_RESOURCE_GROUP" ]]; then
        log_error "Resource group required for storage creation"
        exit 1
    fi

    if [[ -x "$SCRIPT_DIR/create-azure-storage.sh" ]]; then
        log_info "Creating Azure storage..."
        "$SCRIPT_DIR/create-azure-storage.sh" -g "$AZURE_RESOURCE_GROUP"
        
        # Reload environment
        if [[ -f "$PROJECT_ROOT/.env.generated" ]]; then
            source "$PROJECT_ROOT/.env.generated"
        fi
        
        log_success "Azure storage configured"
    else
        log_error "Storage script not found: $SCRIPT_DIR/create-azure-storage.sh"
        return 1
    fi
}

# Step 3: Upload packages
step_upload_packages() {
    echo ""
    echo "=============================================="
    echo "Step 3: Upload Packages to Azure"
    echo "=============================================="

    if [[ -x "$SCRIPT_DIR/upload-to-azure.sh" ]]; then
        log_info "Uploading packages..."
        "$SCRIPT_DIR/upload-to-azure.sh" \
            --storage-account "$AZURE_STORAGE_ACCOUNT" \
            --container "$AZURE_STORAGE_CONTAINER" \
            --repo-path "$REPO_PATH"
        log_success "Packages uploaded"
    else
        log_error "Upload script not found: $SCRIPT_DIR/upload-to-azure.sh"
        return 1
    fi
}

# Step 4: Test repository
step_test_repository() {
    echo ""
    echo "=============================================="
    echo "Step 4: Test Repository"
    echo "=============================================="

    if [[ -x "$SCRIPT_DIR/test-repository.sh" ]]; then
        log_info "Testing repository..."
        "$SCRIPT_DIR/test-repository.sh" \
            --storage-account "$AZURE_STORAGE_ACCOUNT" \
            --container "$AZURE_STORAGE_CONTAINER" \
            --repo-path "$REPO_PATH"
        log_success "Repository tests passed"
    else
        log_error "Test script not found: $SCRIPT_DIR/test-repository.sh"
        return 1
    fi
}

# Step 5: Simulate client access
step_test_client_access() {
    echo ""
    echo "=============================================="
    echo "Step 5: Test Client Access Pattern"
    echo "=============================================="

    log_info "Simulating dnf-plugin-azure-auth behavior..."

    # Get token like the plugin does
    local token
    token=$(az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)

    local base_url="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/${REPO_PATH}"

    # Test repomd.xml access (what dnf does first)
    log_info "Testing repomd.xml access with Bearer token..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "x-ms-version: 2022-11-02" \
        "${base_url}/repodata/repomd.xml")

    if [[ "$http_code" == "200" ]]; then
        log_success "Client access simulation successful (HTTP $http_code)"
    else
        log_error "Client access failed (HTTP $http_code)"
        return 1
    fi

    # Download repomd.xml to verify content
    log_info "Verifying repomd.xml content..."
    local repomd_content
    repomd_content=$(curl -s \
        -H "Authorization: Bearer ${token}" \
        -H "x-ms-version: 2022-11-02" \
        "${base_url}/repodata/repomd.xml" | head -5)

    if echo "$repomd_content" | grep -q "repomd"; then
        log_success "repomd.xml content verified"
    else
        log_warning "repomd.xml content may be invalid"
    fi

    log_success "Client access pattern works correctly"
}

# Cleanup resources
cleanup_resources() {
    echo ""
    echo "=============================================="
    echo "Cleanup"
    echo "=============================================="

    if ! $CLEANUP; then
        log_info "Skipping cleanup (use --cleanup to remove resources)"
        return 0
    fi

    if [[ -n "$AZURE_RESOURCE_GROUP" ]]; then
        log_warning "Deleting resource group: $AZURE_RESOURCE_GROUP"
        read -p "Are you sure? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            az group delete --name "$AZURE_RESOURCE_GROUP" --yes --no-wait
            log_success "Resource group deletion initiated"
        else
            log_info "Cleanup cancelled"
        fi
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo "End-to-End Test Complete"
    echo "=============================================="
    echo ""
    echo "Storage Account: $AZURE_STORAGE_ACCOUNT"
    echo "Container:       $AZURE_STORAGE_CONTAINER"
    echo "Repo Path:       $REPO_PATH"
    echo ""
    echo "Repository URL:"
    echo "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/${REPO_PATH}"
    echo ""
    echo "Client Configuration:"
    echo "1. Install dnf-plugin-azure-auth package"
    echo "2. Run: az login (or use managed identity)"
    echo "3. Configure /etc/yum.repos.d/azure-rpm.repo"
    echo ""
    log_success "All tests passed!"
}

# Main function
main() {
    echo ""
    echo "======================================================="
    echo "Azure Blob RPM Repository - End-to-End Test (Azure AD)"
    echo "======================================================="
    
    parse_args "$@"
    verify_azure_login
    
    local start_time
    start_time=$(date +%s)

    step_build_packages
    step_setup_storage
    step_upload_packages
    step_test_repository
    step_test_client_access

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    print_summary
    echo "Total time: ${duration} seconds"
    
    cleanup_resources
}

main "$@"
