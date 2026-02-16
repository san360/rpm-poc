#!/bin/bash
#===============================================================================
# Test Azure Blob RPM Repository with Azure AD Authentication
# Verifies repository accessibility and package availability
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
REPO_PATH="${REPO_PATH:-el9/x86_64}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Test Azure Blob RPM repository accessibility using Azure AD authentication.

Options:
  --storage-account, -s   Azure storage account name
  --container, -c         Blob container name (default: rpm-repo)
  --repo-path, -r         Repository path (default: el9/x86_64)
  --verbose, -v           Show verbose output
  --help, -h              Show this help message

Environment Variables:
  AZURE_STORAGE_ACCOUNT   Storage account name
  AZURE_STORAGE_CONTAINER Container name
  REPO_PATH               Repository path

Examples:
  $0 -s rpmrepopoc12345
  $0 -s rpmrepopoc12345 -r el8/x86_64 -v

EOF
    exit 0
}

VERBOSE=false

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
            --verbose|-v)
                VERBOSE=true
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

# Validate configuration
validate_config() {
    if [[ -z "$AZURE_STORAGE_ACCOUNT" ]]; then
        log_error "Missing required: AZURE_STORAGE_ACCOUNT"
        exit 1
    fi
}

# Get Azure AD token for storage
get_azure_token() {
    log_info "Getting Azure AD access token..."
    if ! az account show &>/dev/null; then
        log_error "Not logged in to Azure. Run 'az login' first."
        exit 1
    fi

    local token
    token=$(az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)
    
    if [[ -z "$token" ]]; then
        log_error "Failed to get Azure AD token"
        exit 1
    fi
    
    echo "$token"
}

# Test blob accessibility with Azure AD token
test_blob_with_token() {
    local blob_path="$1"
    local token="$2"
    local blob_url="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/${blob_path}"
    
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "x-ms-version: 2022-11-02" \
        "$blob_url")
    
    echo "$http_code"
}

# List blobs in container path
list_blobs() {
    local prefix="$1"
    
    az storage blob list \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --container-name "$AZURE_STORAGE_CONTAINER" \
        --prefix "$prefix" \
        --auth-mode login \
        --query "[].{name:name, size:properties.contentLength}" \
        -o table 2>/dev/null || echo "Failed to list blobs"
}

# Run tests
run_tests() {
    local base_url="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/${REPO_PATH}"
    local tests_passed=0
    local tests_failed=0

    echo ""
    echo "=============================================="
    echo "Azure Blob RPM Repository Tests"
    echo "=============================================="
    echo "Storage Account: $AZURE_STORAGE_ACCOUNT"
    echo "Container:       $AZURE_STORAGE_CONTAINER"
    echo "Repo Path:       $REPO_PATH"
    echo "Base URL:        $base_url"
    echo ""

    # Get token
    local token
    token=$(get_azure_token)
    log_success "Azure AD token obtained"

    echo ""
    echo "--- Testing Repository Access ---"

    # Test 1: Check repomd.xml accessibility
    log_info "Testing repomd.xml access..."
    local repomd_code
    repomd_code=$(test_blob_with_token "${REPO_PATH}/repodata/repomd.xml" "$token")
    
    if [[ "$repomd_code" == "200" ]]; then
        log_success "repomd.xml accessible (HTTP $repomd_code)"
        tests_passed=$((tests_passed + 1))
    else
        log_error "repomd.xml not accessible (HTTP $repomd_code)"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 2: Check for primary.xml.gz
    log_info "Testing primary.xml.gz access..."
    local primary_code
    primary_code=$(test_blob_with_token "${REPO_PATH}/repodata/primary.xml.gz" "$token")
    
    if [[ "$primary_code" == "200" ]]; then
        log_success "primary.xml.gz accessible (HTTP $primary_code)"
        tests_passed=$((tests_passed + 1))
    else
        log_warning "primary.xml.gz not accessible (HTTP $primary_code) - may have different name"
    fi

    # Test 3: List packages
    echo ""
    echo "--- Package Listing ---"
    log_info "Listing packages in repository..."
    
    if $VERBOSE; then
        list_blobs "${REPO_PATH}/"
    fi
    
    local pkg_count
    pkg_count=$(az storage blob list \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --container-name "$AZURE_STORAGE_CONTAINER" \
        --prefix "${REPO_PATH}/" \
        --auth-mode login \
        --query "length([?ends_with(name, '.rpm')])" \
        -o tsv 2>/dev/null || echo "0")
    
    if [[ "$pkg_count" -gt 0 ]]; then
        log_success "Found $pkg_count RPM package(s)"
        tests_passed=$((tests_passed + 1))
    else
        log_warning "No RPM packages found in ${REPO_PATH}/Packages/"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 4: Test repodata file count
    log_info "Checking repodata files..."
    local repodata_count
    repodata_count=$(az storage blob list \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --container-name "$AZURE_STORAGE_CONTAINER" \
        --prefix "${REPO_PATH}/repodata/" \
        --auth-mode login \
        --query "length([])" \
        -o tsv 2>/dev/null || echo "0")
    
    if [[ "$repodata_count" -gt 0 ]]; then
        log_success "Found $repodata_count repodata file(s)"
        tests_passed=$((tests_passed + 1))
    else
        log_error "No repodata files found"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 5: Verify token-based access works (negative test for anonymous)
    echo ""
    echo "--- Security Tests ---"
    log_info "Testing anonymous access (should fail)..."
    local anon_code
    anon_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "${base_url}/repodata/repomd.xml" 2>/dev/null || echo "000")
    
    if [[ "$anon_code" == "404" || "$anon_code" == "403" || "$anon_code" == "409" ]]; then
        log_success "Anonymous access blocked (HTTP $anon_code) - Security OK"
        tests_passed=$((tests_passed + 1))
    elif [[ "$anon_code" == "200" ]]; then
        log_warning "Anonymous access allowed (HTTP $anon_code) - Consider disabling public access"
    else
        log_info "Anonymous access result: HTTP $anon_code"
    fi

    # Summary
    echo ""
    echo "=============================================="
    echo "Test Summary"
    echo "=============================================="
    echo -e "Passed: ${GREEN}$tests_passed${NC}"
    echo -e "Failed: ${RED}$tests_failed${NC}"
    echo ""

    if [[ $tests_failed -eq 0 ]]; then
        log_success "All tests passed! Repository is ready for use."
        return 0
    else
        log_warning "Some tests failed. Please review the output above."
        return 1
    fi
}

# Main function
main() {
    parse_args "$@"
    validate_config
    run_tests
}

main "$@"
