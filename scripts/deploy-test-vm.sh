#!/bin/bash
#===============================================================================
# Deploy RHEL 9 Test VM with Managed Identity
# For testing Azure Blob RPM Repository with Azure AD Authentication
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

# Default values (can be overridden via environment variables or parameters)
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
LOCATION="${LOCATION:-swedencentral}"
VM_NAME="${VM_NAME:-rpm-test-vm}"
VM_SIZE="${VM_SIZE:-Standard_DS2_v2}"
ADMIN_USERNAME="${ADMIN_USERNAME:-azureuser}"
ADMIN_PASSWORD=""
VM_IMAGE="RedHat:RHEL:9-lvm-gen2:latest"
VM_PUBLIC_IP=""

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploys a RHEL 9 VM with system-assigned Managed Identity for testing
Azure Blob RPM Repository with Azure AD authentication.

The script will:
  1. Tag the resource group with SecurityControle=Ignore
  2. Generate a secure admin password
  3. Accept RHEL marketplace image terms
  4. Create a RHEL 9 VM with system-assigned Managed Identity
  5. Assign Storage Blob Data Reader role to the VM's identity
  6. Save credentials to .env.vm-credentials

Required Parameters:
  --resource-group, -g      Resource group name (or set RESOURCE_GROUP env var)
  --storage-account, -s     Storage account name (or set AZURE_STORAGE_ACCOUNT env var)

Optional Parameters:
  --vm-name, -n             VM name (default: rpm-test-vm)
  --vm-size                 VM size (default: Standard_DS2_v2)
  --location, -l            Azure region (default: swedencentral)
  --admin-username, -u      Admin username (default: azureuser)
  --help, -h                Show this help message

Examples:
  # Using .env.generated (auto-detected)
  $0

  # Explicit parameters
  $0 -g rg-rpm-poc -s rpmrepopoc37333

  # Custom VM name and size
  $0 -g rg-rpm-poc -s rpmrepopoc37333 -n my-test-vm --vm-size Standard_B1s

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

# Load environment from .env.generated
load_env() {
    local env_file="$PROJECT_ROOT/.env.generated"
    if [[ -f "$env_file" ]]; then
        log_info "Loading configuration from .env.generated"
        # Source only if variables are not already set
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Only set if not already set via CLI args
            if [[ -z "${!key:-}" ]]; then
                export "$key=$value"
            fi
        done < <(grep -v '^#' "$env_file" | grep '=')

        # Map AZURE_STORAGE_ACCOUNT if not set
        if [[ -z "$AZURE_STORAGE_ACCOUNT" ]] && [[ -n "${AZURE_STORAGE_ACCOUNT:-}" ]]; then
            AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT}"
        fi
        RESOURCE_GROUP="${RESOURCE_GROUP:-}"
        LOCATION="${LOCATION:-swedencentral}"
    else
        log_warning "No .env.generated found. Provide parameters via CLI flags."
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --resource-group|-g)
                RESOURCE_GROUP="$2"
                shift 2
                ;;
            --storage-account|-s)
                AZURE_STORAGE_ACCOUNT="$2"
                shift 2
                ;;
            --vm-name|-n)
                VM_NAME="$2"
                shift 2
                ;;
            --vm-size)
                VM_SIZE="$2"
                shift 2
                ;;
            --location|-l)
                LOCATION="$2"
                shift 2
                ;;
            --admin-username|-u)
                ADMIN_USERNAME="$2"
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

    if [[ -z "$RESOURCE_GROUP" ]]; then
        log_error "Resource group is required (--resource-group or RESOURCE_GROUP env var)"
        missing=true
    fi

    if [[ -z "$AZURE_STORAGE_ACCOUNT" ]]; then
        log_error "Storage account is required (--storage-account or AZURE_STORAGE_ACCOUNT env var)"
        missing=true
    fi

    if [[ "$missing" == "true" ]]; then
        echo ""
        usage
    fi

    log_info "Configuration:"
    log_info "  Resource Group:    $RESOURCE_GROUP"
    log_info "  Storage Account:   $AZURE_STORAGE_ACCOUNT"
    log_info "  Location:          $LOCATION"
    log_info "  VM Name:           $VM_NAME"
    log_info "  VM Size:           $VM_SIZE"
    log_info "  VM Image:          $VM_IMAGE"
    log_info "  Admin Username:    $ADMIN_USERNAME"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Azure CLI
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed. Install with: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
        exit 1
    fi
    log_success "Azure CLI is installed"

    # Check login status
    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure. Run: az login"
        exit 1
    fi
    log_success "Azure CLI is authenticated"

    # Check resource group exists
    if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        log_error "Resource group '$RESOURCE_GROUP' does not exist. Run create-azure-storage.sh first."
        exit 1
    fi
    log_success "Resource group '$RESOURCE_GROUP' exists"

    # Check storage account exists
    if ! az storage account show --name "$AZURE_STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        log_error "Storage account '$AZURE_STORAGE_ACCOUNT' not found in resource group '$RESOURCE_GROUP'"
        exit 1
    fi
    log_success "Storage account '$AZURE_STORAGE_ACCOUNT' exists"
}

# Generate Azure-compliant password
generate_password() {
    log_info "Generating secure admin password..."

    # Azure requires: 12+ chars, mix of uppercase, lowercase, digit, special char
    local base
    base=$(openssl rand -base64 12)
    ADMIN_PASSWORD="${base}Aa1!"

    log_success "Secure admin password generated"
}

# Tag resource group with SecurityControle=Ignore
tag_resource_group() {
    log_info "Ensuring SecurityControle=Ignore tag on resource group '$RESOURCE_GROUP'..."

    local rg_id
    rg_id=$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)

    az tag update \
        --resource-id "$rg_id" \
        --operation merge \
        --tags SecurityControle=Ignore > /dev/null

    log_success "Resource group tagged with SecurityControle=Ignore"
}

# Accept RHEL marketplace image terms
accept_image_terms() {
    log_info "Accepting marketplace terms for $VM_IMAGE..."

    az vm image terms accept --urn "$VM_IMAGE" --only-show-errors > /dev/null 2>&1 || true

    log_success "Marketplace terms accepted"
}

# Create the RHEL 9 VM with Managed Identity
create_vm() {
    # Check if VM already exists
    if az vm show --name "$VM_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        log_warning "VM '$VM_NAME' already exists in resource group '$RESOURCE_GROUP'"
        VM_PUBLIC_IP=$(az vm show \
            --name "$VM_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --show-details \
            --query publicIps -o tsv)
        log_info "Existing VM public IP: $VM_PUBLIC_IP"
        return 0
    fi

    log_info "Creating RHEL 9 VM '$VM_NAME' (size: $VM_SIZE)..."
    log_info "This may take 2-3 minutes..."

    az vm create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --location "$LOCATION" \
        --image "$VM_IMAGE" \
        --size "$VM_SIZE" \
        --admin-username "$ADMIN_USERNAME" \
        --admin-password "$ADMIN_PASSWORD" \
        --assign-identity '[system]' \
        --public-ip-sku Standard \
        --nsg-rule SSH \
        --tags environment=poc project=rpm-repository SecurityControle=Ignore \
        --only-show-errors \
        --output none

    VM_PUBLIC_IP=$(az vm show \
        --name "$VM_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --show-details \
        --query publicIps -o tsv)

    log_success "VM '$VM_NAME' created with public IP: $VM_PUBLIC_IP"
}

# Assign Storage Blob Data Reader role to VM's managed identity
assign_blob_reader_role() {
    log_info "Assigning Storage Blob Data Reader role to VM managed identity..."

    # Get VM's managed identity principal ID
    local vm_principal_id
    vm_principal_id=$(az vm show \
        --name "$VM_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query identity.principalId -o tsv)

    if [[ -z "$vm_principal_id" || "$vm_principal_id" == "None" ]]; then
        log_error "VM does not have a managed identity. This should not happen."
        exit 1
    fi
    log_info "VM Managed Identity Principal ID: $vm_principal_id"

    # Get storage account resource ID
    local storage_id
    storage_id=$(az storage account show \
        --name "$AZURE_STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --query id -o tsv)

    # Check if role assignment already exists
    local existing_assignment
    existing_assignment=$(az role assignment list \
        --assignee "$vm_principal_id" \
        --role "Storage Blob Data Reader" \
        --scope "$storage_id" \
        --query "[].id" -o tsv 2>/dev/null || true)

    if [[ -n "$existing_assignment" ]]; then
        log_warning "Storage Blob Data Reader role already assigned to VM"
        return 0
    fi

    az role assignment create \
        --role "Storage Blob Data Reader" \
        --assignee-object-id "$vm_principal_id" \
        --assignee-principal-type ServicePrincipal \
        --scope "$storage_id" \
        --only-show-errors \
        --output none

    log_success "Storage Blob Data Reader role assigned to VM managed identity"

    # Wait for RBAC propagation
    log_info "Waiting 30 seconds for RBAC role propagation..."
    sleep 30
    log_success "RBAC propagation wait complete"
}

# Wait for VM to be fully ready
wait_for_vm_ready() {
    log_info "Waiting for VM to be ready..."

    # Check VM power state
    local power_state
    power_state=$(az vm get-instance-view \
        --name "$VM_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" \
        -o tsv)

    if [[ "$power_state" != "VM running" ]]; then
        log_warning "VM power state: $power_state. Waiting..."
        az vm wait \
            --name "$VM_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --custom "instanceView.statuses[?code=='PowerState/running']" \
            --timeout 120
    fi

    log_success "VM is running"
}

# Save credentials to .env.vm-credentials
save_credentials() {
    local creds_file="$PROJECT_ROOT/.env.vm-credentials"

    log_info "Saving VM credentials to .env.vm-credentials..."

    cat > "$creds_file" << EOF
# VM Credentials - KEEP SECRET (git-ignored)
# Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# VM deployed for testing managed identity access to Azure Blob RPM repository

VM_NAME=$VM_NAME
VM_PUBLIC_IP=$VM_PUBLIC_IP
VM_ADMIN_USERNAME=$ADMIN_USERNAME
VM_ADMIN_PASSWORD=$ADMIN_PASSWORD
VM_RESOURCE_GROUP=$RESOURCE_GROUP
VM_IMAGE=$VM_IMAGE
VM_SIZE=$VM_SIZE
EOF

    chmod 600 "$creds_file"
    log_success "Credentials saved to: $creds_file (permissions: 600)"
}

# Display summary
show_summary() {
    echo ""
    echo "======================================================="
    echo -e "${GREEN}VM Deployment Complete${NC}"
    echo "======================================================="
    echo ""
    echo "  VM Name:           $VM_NAME"
    echo "  Public IP:         $VM_PUBLIC_IP"
    echo "  Username:          $ADMIN_USERNAME"
    echo "  Image:             $VM_IMAGE"
    echo "  Size:              $VM_SIZE"
    echo "  Managed Identity:  System-assigned (enabled)"
    echo "  RBAC Role:         Storage Blob Data Reader"
    echo "  Resource Group:    $RESOURCE_GROUP"
    echo "  RG Tag:            SecurityControle=Ignore"
    echo ""
    echo "  Credentials file:  .env.vm-credentials"
    echo ""
    echo "  SSH command:"
    echo "    ssh ${ADMIN_USERNAME}@${VM_PUBLIC_IP}"
    echo ""
    echo "  Next step - run the managed identity test:"
    echo "    ./scripts/test-vm-managed-identity.sh"
    echo ""
    echo "  Cleanup:"
    echo "    az vm delete --name $VM_NAME --resource-group $RESOURCE_GROUP --yes"
    echo ""
    echo "======================================================="
}

# Main orchestration
main() {
    echo ""
    echo "======================================================="
    echo "Deploy RHEL 9 Test VM with Managed Identity"
    echo "======================================================="
    echo ""

    parse_args "$@"
    load_env
    validate_params

    local start_time
    start_time=$(date +%s)

    check_prerequisites
    generate_password
    tag_resource_group
    accept_image_terms
    create_vm
    assign_blob_reader_role
    wait_for_vm_ready
    save_credentials
    show_summary

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_info "Total deployment time: ${duration} seconds"
}

main "$@"
