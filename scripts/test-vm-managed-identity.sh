#!/bin/bash
#===============================================================================
# Test Managed Identity Access to Azure Blob RPM Repository
# SSHes into a deployed VM and validates the full workflow
#===============================================================================

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default values
VM_PUBLIC_IP="${VM_PUBLIC_IP:-}"
VM_ADMIN_USERNAME="${VM_ADMIN_USERNAME:-azureuser}"
VM_ADMIN_PASSWORD="${VM_ADMIN_PASSWORD:-}"
AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
AZURE_STORAGE_CONTAINER="${AZURE_STORAGE_CONTAINER:-rpm-repo}"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_STEPS=10

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

SSHes into a deployed RHEL 9 VM and tests managed identity access
to the Azure Blob RPM Repository.

This script will:
  1. Install Azure CLI on the VM
  2. Login with managed identity (az login --identity)
  3. Upload and install the dnf-plugin-azure-auth RPM
  4. Configure the plugin and repository
  5. Test dnf makecache, list packages, and install hello-azure
  6. Verify the token source is managed identity

Prerequisites:
  - VM deployed with deploy-test-vm.sh (or .env.vm-credentials exists)
  - sshpass installed locally (apt-get install sshpass)

Parameters:
  --vm-ip                   VM public IP address
  --vm-user                 VM admin username (default: azureuser)
  --vm-password             VM admin password
  --storage-account, -s     Storage account name
  --container, -c           Container name (default: rpm-repo)
  --help, -h                Show this help message

Examples:
  # Auto-detect from .env files
  $0

  # Explicit parameters
  $0 --vm-ip 1.2.3.4 --vm-user azureuser --vm-password 'MyPass!' \\
     -s rpmrepopoc37333

EOF
    exit 1
}

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Test result tracking
record_pass() {
    local test_name="$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}  ✓ PASS:${NC} $test_name"
}

record_fail() {
    local test_name="$1"
    local detail="${2:-}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}  ✗ FAIL:${NC} $test_name"
    if [[ -n "$detail" ]]; then
        echo -e "${RED}         ${NC} $detail"
    fi
}

# Load environment from .env files
load_env() {
    # Load .env.generated for storage account info
    local env_file="$PROJECT_ROOT/.env.generated"
    if [[ -f "$env_file" ]]; then
        log_info "Loading configuration from .env.generated"
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ -z "${!key:-}" ]]; then
                export "$key=$value"
            fi
        done < <(grep -v '^#' "$env_file" | grep '=')
    fi

    # Load .env.vm-credentials for VM connection info
    local creds_file="$PROJECT_ROOT/.env.vm-credentials"
    if [[ -f "$creds_file" ]]; then
        log_info "Loading VM credentials from .env.vm-credentials"
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ -z "${!key:-}" ]]; then
                export "$key=$value"
            fi
        done < <(grep -v '^#' "$creds_file" | grep '=')
    fi

    # Re-read variables after sourcing
    VM_PUBLIC_IP="${VM_PUBLIC_IP:-}"
    VM_ADMIN_USERNAME="${VM_ADMIN_USERNAME:-azureuser}"
    VM_ADMIN_PASSWORD="${VM_ADMIN_PASSWORD:-}"
    AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
    AZURE_STORAGE_CONTAINER="${AZURE_STORAGE_CONTAINER:-rpm-repo}"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --vm-ip)
                VM_PUBLIC_IP="$2"
                shift 2
                ;;
            --vm-user)
                VM_ADMIN_USERNAME="$2"
                shift 2
                ;;
            --vm-password)
                VM_ADMIN_PASSWORD="$2"
                shift 2
                ;;
            --storage-account|-s)
                AZURE_STORAGE_ACCOUNT="$2"
                shift 2
                ;;
            --container|-c)
                AZURE_STORAGE_CONTAINER="$2"
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

# Validate required parameters
validate_params() {
    local missing=false

    if [[ -z "$VM_PUBLIC_IP" ]]; then
        log_error "VM public IP is required (--vm-ip or deploy with deploy-test-vm.sh first)"
        missing=true
    fi

    if [[ -z "$VM_ADMIN_PASSWORD" ]]; then
        log_error "VM admin password is required (--vm-password or .env.vm-credentials)"
        missing=true
    fi

    if [[ -z "$AZURE_STORAGE_ACCOUNT" ]]; then
        log_error "Storage account is required (--storage-account or .env.generated)"
        missing=true
    fi

    if [[ "$missing" == "true" ]]; then
        echo ""
        usage
    fi

    log_info "Test Configuration:"
    log_info "  VM IP:             $VM_PUBLIC_IP"
    log_info "  VM Username:       $VM_ADMIN_USERNAME"
    log_info "  Storage Account:   $AZURE_STORAGE_ACCOUNT"
    log_info "  Container:         $AZURE_STORAGE_CONTAINER"
}

# Check that sshpass is installed locally
check_sshpass_installed() {
    if ! command -v sshpass &> /dev/null; then
        log_error "sshpass is not installed. Install with:"
        echo "  sudo apt-get install -y sshpass"
        exit 1
    fi
    log_success "sshpass is available"
}

# SSH wrapper - execute a command on the VM
run_ssh_command() {
    local description="$1"
    shift

    if [[ -n "$description" ]]; then
        log_info "$description"
    fi

    sshpass -p "$VM_ADMIN_PASSWORD" \
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            -o LogLevel=ERROR \
            "${VM_ADMIN_USERNAME}@${VM_PUBLIC_IP}" \
            "$@"
}

# SCP wrapper - copy file to the VM
scp_to_vm() {
    local local_path="$1"
    local remote_path="$2"

    sshpass -p "$VM_ADMIN_PASSWORD" \
        scp -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$local_path" \
            "${VM_ADMIN_USERNAME}@${VM_PUBLIC_IP}:${remote_path}"
}

# Wait for SSH connectivity
check_ssh_connectivity() {
    log_info "Waiting for SSH connectivity to $VM_PUBLIC_IP..."

    local max_retries=24
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        if sshpass -p "$VM_ADMIN_PASSWORD" \
            ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=5 \
                -o LogLevel=ERROR \
                "${VM_ADMIN_USERNAME}@${VM_PUBLIC_IP}" \
                "echo 'connected'" &> /dev/null; then
            log_success "SSH connection established"
            return 0
        fi
        retry=$((retry + 1))
        log_info "Waiting for SSH... (attempt $retry/$max_retries)"
        sleep 5
    done

    log_error "SSH connection timed out after 120 seconds"
    exit 1
}

#===============================================================================
# Test Steps
#===============================================================================

step_install_azure_cli() {
    echo ""
    echo "=============================================="
    echo " Step 1/$TOTAL_STEPS: Install Azure CLI on VM"
    echo "=============================================="

    # Check if Azure CLI is already installed
    if run_ssh_command "" "command -v az" &> /dev/null; then
        log_info "Azure CLI already installed on VM"
        run_ssh_command "Checking Azure CLI version..." "az --version 2>/dev/null | head -1"
        record_pass "Azure CLI installed"
        return 0
    fi

    run_ssh_command "Importing Microsoft RPM key..." \
        "sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc"

    run_ssh_command "Adding Azure CLI yum repository..." \
        "sudo dnf config-manager --add-repo https://packages.microsoft.com/yumrepos/azure-cli"

    run_ssh_command "Installing Azure CLI (this may take a few minutes)..." \
        "sudo dnf install -y azure-cli"

    # Verify installation
    if run_ssh_command "" "az --version" &> /dev/null; then
        record_pass "Azure CLI installed"
    else
        record_fail "Azure CLI installation"
        exit 1
    fi
}

step_login_managed_identity() {
    echo ""
    echo "=============================================="
    echo " Step 2/$TOTAL_STEPS: Login with Managed Identity"
    echo "=============================================="

    run_ssh_command "Running az login --identity..." \
        "az login --identity --only-show-errors"

    # Verify login
    local account_info
    account_info=$(run_ssh_command "" "az account show --query '{name:name, id:id}' -o tsv" 2>/dev/null) || true

    if [[ -n "$account_info" ]]; then
        log_info "Logged in as managed identity"
        log_info "Account: $account_info"
        record_pass "Managed Identity login"
    else
        record_fail "Managed Identity login" "az login --identity failed"
        exit 1
    fi
}

step_upload_plugin_rpm() {
    echo ""
    echo "=============================================="
    echo " Step 3/$TOTAL_STEPS: Upload plugin RPM to VM"
    echo "=============================================="

    # Find the plugin RPM locally
    local plugin_rpm
    plugin_rpm=$(find "$PROJECT_ROOT/packages" -name "dnf-plugin-azure-auth-*.rpm" -type f 2>/dev/null | head -1)

    if [[ -z "$plugin_rpm" ]]; then
        record_fail "Upload plugin RPM" "dnf-plugin-azure-auth RPM not found in packages/"
        log_error "Build the plugin first with: ./scripts/build-rpm-local.sh all"
        exit 1
    fi

    log_info "Uploading $(basename "$plugin_rpm") to VM..."
    scp_to_vm "$plugin_rpm" "/tmp/"

    if run_ssh_command "" "ls /tmp/dnf-plugin-azure-auth-*.rpm" &> /dev/null; then
        record_pass "Plugin RPM uploaded to VM"
    else
        record_fail "Plugin RPM upload"
        exit 1
    fi
}

step_install_plugin() {
    echo ""
    echo "=============================================="
    echo " Step 4/$TOTAL_STEPS: Install plugin on VM"
    echo "=============================================="

    run_ssh_command "Installing dnf-plugin-azure-auth..." \
        "sudo dnf install -y /tmp/dnf-plugin-azure-auth-*.rpm"

    # Verify installation
    if run_ssh_command "" "test -f /usr/lib/python3/site-packages/dnf-plugins/azure_auth.py" &> /dev/null; then
        record_pass "Plugin installed"
    else
        record_fail "Plugin installation" "azure_auth.py not found in plugin directory"
        exit 1
    fi
}

step_configure_plugin() {
    echo ""
    echo "=============================================="
    echo " Step 5/$TOTAL_STEPS: Configure plugin"
    echo "=============================================="

    # Check if section already exists
    if run_ssh_command "" "grep -q '\\[azure-rpm-repo\\]' /etc/dnf/plugins/azure_auth.conf 2>/dev/null"; then
        log_info "Plugin already configured for azure-rpm-repo"
        record_pass "Plugin configured"
        return 0
    fi

    run_ssh_command "Adding azure-rpm-repo section to plugin config..." \
        "echo -e '\\n[azure-rpm-repo]' | sudo tee -a /etc/dnf/plugins/azure_auth.conf > /dev/null"

    run_ssh_command "Plugin configuration:" \
        "cat /etc/dnf/plugins/azure_auth.conf"

    record_pass "Plugin configured"
}

step_configure_repo() {
    echo ""
    echo "=============================================="
    echo " Step 6/$TOTAL_STEPS: Configure RPM repository"
    echo "=============================================="

    local baseurl="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/el9/x86_64"

    run_ssh_command "Creating /etc/yum.repos.d/azure-rpm.repo..." \
        "sudo tee /etc/yum.repos.d/azure-rpm.repo > /dev/null << 'REPOEOF'
[azure-rpm-repo]
name=Azure Blob RPM Repository
baseurl=${baseurl}
enabled=1
gpgcheck=0
sslverify=1
metadata_expire=3600
REPOEOF"

    run_ssh_command "Repository configuration:" \
        "cat /etc/yum.repos.d/azure-rpm.repo"

    record_pass "Repository configured"
}

step_test_makecache() {
    echo ""
    echo "=============================================="
    echo " Step 7/$TOTAL_STEPS: Test dnf makecache"
    echo "=============================================="

    log_info "Running dnf makecache (this tests managed identity token injection)..."

    if run_ssh_command "" "sudo dnf makecache --disablerepo='*' --enablerepo='azure-rpm-repo'" 2>&1; then
        record_pass "dnf makecache with managed identity"
    else
        record_fail "dnf makecache" "Plugin failed to authenticate with managed identity"
        return 1
    fi
}

step_test_list_packages() {
    echo ""
    echo "=============================================="
    echo " Step 8/$TOTAL_STEPS: List available packages"
    echo "=============================================="

    local output
    output=$(run_ssh_command "" \
        "sudo dnf --disablerepo='*' --enablerepo='azure-rpm-repo' list available 2>/dev/null" || true)

    if [[ -n "$output" ]]; then
        echo "$output"
        record_pass "List packages from Azure Blob repo"
    else
        record_fail "List packages" "No packages found in repository"
        return 1
    fi
}

step_test_install_package() {
    echo ""
    echo "=============================================="
    echo " Step 9/$TOTAL_STEPS: Install hello-azure package"
    echo "=============================================="

    log_info "Installing hello-azure from Azure Blob RPM repository..."

    if run_ssh_command "" "sudo dnf install -y --disablerepo='*' --enablerepo='azure-rpm-repo' hello-azure" 2>&1; then
        echo ""
        log_info "Running hello-azure..."
        run_ssh_command "" "hello-azure" || true
        record_pass "Install hello-azure via managed identity"
    else
        record_fail "Install hello-azure" "Package installation failed"
        return 1
    fi
}

step_verify_token_source() {
    echo ""
    echo "=============================================="
    echo " Step 10/$TOTAL_STEPS: Verify managed identity token"
    echo "=============================================="

    local user_type
    user_type=$(run_ssh_command "" "az account show --query user.type -o tsv 2>/dev/null" || true)

    if [[ "$user_type" == "servicePrincipal" ]]; then
        log_info "Token source: $user_type (managed identity)"
        record_pass "Token is from managed identity"
    else
        record_fail "Token source verification" "Expected servicePrincipal, got: $user_type"
        return 1
    fi

    # Also verify we can get a storage token
    local token_check
    token_check=$(run_ssh_command "" \
        "az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv 2>/dev/null | head -c 20" || true)

    if [[ -n "$token_check" ]]; then
        log_info "Storage token acquired via managed identity (starts with: ${token_check}...)"
        record_pass "Storage token via managed identity"
    else
        record_fail "Storage token acquisition"
    fi
}

# Print final test summary
print_test_summary() {
    local total=$((TESTS_PASSED + TESTS_FAILED))

    echo ""
    echo "======================================================="
    echo " Managed Identity Test Results"
    echo "======================================================="
    echo ""
    echo "  Tests passed:  $TESTS_PASSED"
    echo "  Tests failed:  $TESTS_FAILED"
    echo "  Total tests:   $total"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "  ${GREEN}All tests passed!${NC}"
        echo ""
        echo "  The managed identity authentication flow is working correctly:"
        echo "  VM → az login --identity → IMDS → Azure AD token"
        echo "  → dnf-plugin-azure-auth → Bearer token → Azure Blob Storage"
    else
        echo -e "  ${RED}Some tests failed.${NC}"
        echo "  Review the output above for details."
    fi

    echo ""
    echo "  Cleanup:"
    echo "    az vm delete --name ${VM_NAME:-rpm-test-vm} --resource-group ${VM_RESOURCE_GROUP:-$RESOURCE_GROUP} --yes"
    echo ""
    echo "======================================================="
}

# Main orchestration
main() {
    echo ""
    echo "======================================================="
    echo "Azure VM Managed Identity Test (RHEL 9)"
    echo "======================================================="
    echo ""

    parse_args "$@"
    load_env
    validate_params
    check_sshpass_installed
    check_ssh_connectivity

    local start_time
    start_time=$(date +%s)

    step_install_azure_cli          # Step 1
    step_login_managed_identity     # Step 2
    step_upload_plugin_rpm          # Step 3
    step_install_plugin             # Step 4
    step_configure_plugin           # Step 5
    step_configure_repo             # Step 6
    step_test_makecache             # Step 7
    step_test_list_packages         # Step 8
    step_test_install_package       # Step 9
    step_verify_token_source        # Step 10

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    print_test_summary
    log_info "Total test time: ${duration} seconds"

    # Exit with failure if any tests failed
    [[ $TESTS_FAILED -eq 0 ]]
}

main "$@"
