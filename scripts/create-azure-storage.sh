#!/bin/bash
#===============================================================================
# Azure Storage Account Creation Script with Private Endpoint
# For RPM Repository Hosting
#===============================================================================

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values (can be overridden via environment variables or parameters)
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"
LOCATION="${LOCATION:-eastus}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
VNET_NAME="${VNET_NAME:-}"
VNET_RESOURCE_GROUP="${VNET_RESOURCE_GROUP:-}"
SUBNET_NAME="${SUBNET_NAME:-}"
PRIVATE_ENDPOINT_NAME="${PRIVATE_ENDPOINT_NAME:-}"
CONTAINER_NAME="${CONTAINER_NAME:-rpm-repo}"
SKU="${SKU:-Standard_LRS}"
ENABLE_PRIVATE_ENDPOINT="${ENABLE_PRIVATE_ENDPOINT:-true}"
DISABLE_PUBLIC_ACCESS="${DISABLE_PUBLIC_ACCESS:-false}"
TAGS="${TAGS:-environment=poc project=rpm-repository SecurityControl=Ignore}"

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Creates an Azure Storage Account with optional Private Endpoint for RPM Repository.

Required Parameters:
  --resource-group, -g        Resource group name (or set RESOURCE_GROUP env var)
  --storage-account, -s       Storage account name (or set STORAGE_ACCOUNT_NAME env var)
  --subscription, -sub        Subscription ID (or set SUBSCRIPTION_ID env var)

Private Endpoint Parameters (required if --enable-private-endpoint is true):
  --vnet-name                 Virtual network name (or set VNET_NAME env var)
  --vnet-resource-group       VNet resource group (or set VNET_RESOURCE_GROUP env var)
  --subnet-name               Subnet name for private endpoint (or set SUBNET_NAME env var)

Optional Parameters:
  --location, -l              Azure region (default: eastus)
  --container-name, -c        Blob container name (default: rpm-repo)
  --sku                       Storage SKU (default: Standard_LRS)
  --private-endpoint-name     Private endpoint name (default: <storage-account>-pe)
  --enable-private-endpoint   Enable private endpoint (default: true)
  --disable-public-access     Disable public blob access (default: false)
  --tags                      Resource tags (default: environment=poc project=rpm-repository)
  --help, -h                  Show this help message

Examples:
  # Basic usage with private endpoint
  $0 -g my-rg -s myrpmrepo -sub xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \\
     --vnet-name my-vnet --vnet-resource-group my-vnet-rg --subnet-name private-endpoints

  # Without private endpoint (public access)
  $0 -g my-rg -s myrpmrepo -sub xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \\
     --enable-private-endpoint false

  # Using environment variables
  export RESOURCE_GROUP=my-rg
  export STORAGE_ACCOUNT_NAME=myrpmrepo
  export SUBSCRIPTION_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  $0 --enable-private-endpoint false

EOF
    exit 1
}

# Function to log messages
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

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --resource-group|-g)
                RESOURCE_GROUP="$2"
                shift 2
                ;;
            --storage-account|-s)
                STORAGE_ACCOUNT_NAME="$2"
                shift 2
                ;;
            --subscription|-sub)
                SUBSCRIPTION_ID="$2"
                shift 2
                ;;
            --location|-l)
                LOCATION="$2"
                shift 2
                ;;
            --vnet-name)
                VNET_NAME="$2"
                shift 2
                ;;
            --vnet-resource-group)
                VNET_RESOURCE_GROUP="$2"
                shift 2
                ;;
            --subnet-name)
                SUBNET_NAME="$2"
                shift 2
                ;;
            --container-name|-c)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --sku)
                SKU="$2"
                shift 2
                ;;
            --private-endpoint-name)
                PRIVATE_ENDPOINT_NAME="$2"
                shift 2
                ;;
            --enable-private-endpoint)
                ENABLE_PRIVATE_ENDPOINT="$2"
                shift 2
                ;;
            --disable-public-access)
                DISABLE_PUBLIC_ACCESS="$2"
                shift 2
                ;;
            --tags)
                TAGS="$2"
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
    local missing_params=()

    if [[ -z "$RESOURCE_GROUP" ]]; then
        missing_params+=("--resource-group")
    fi

    if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
        missing_params+=("--storage-account")
    fi

    if [[ -z "$SUBSCRIPTION_ID" ]]; then
        missing_params+=("--subscription")
    fi

    if [[ "$ENABLE_PRIVATE_ENDPOINT" == "true" ]]; then
        if [[ -z "$VNET_NAME" ]]; then
            missing_params+=("--vnet-name (required for private endpoint)")
        fi
        if [[ -z "$VNET_RESOURCE_GROUP" ]]; then
            missing_params+=("--vnet-resource-group (required for private endpoint)")
        fi
        if [[ -z "$SUBNET_NAME" ]]; then
            missing_params+=("--subnet-name (required for private endpoint)")
        fi
    fi

    if [[ ${#missing_params[@]} -gt 0 ]]; then
        log_error "Missing required parameters:"
        for param in "${missing_params[@]}"; do
            echo "  - $param"
        done
        echo ""
        usage
    fi

    # Set default private endpoint name if not provided
    if [[ -z "$PRIVATE_ENDPOINT_NAME" ]]; then
        PRIVATE_ENDPOINT_NAME="${STORAGE_ACCOUNT_NAME}-pe"
    fi

    # Validate storage account name (3-24 chars, lowercase letters and numbers only)
    if ! [[ "$STORAGE_ACCOUNT_NAME" =~ ^[a-z0-9]{3,24}$ ]]; then
        log_error "Storage account name must be 3-24 characters, lowercase letters and numbers only"
        exit 1
    fi
}

# Check Azure CLI is installed and logged in
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if Azure CLI is installed
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed. Please install it first:"
        echo "  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
        exit 1
    fi

    # Check if logged in
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure. Please run: az login"
        exit 1
    fi

    # Set subscription
    log_info "Setting subscription to: $SUBSCRIPTION_ID"
    az account set --subscription "$SUBSCRIPTION_ID"

    log_success "Prerequisites check passed"
}

# Create resource group if it doesn't exist
create_resource_group() {
    log_info "Checking resource group: $RESOURCE_GROUP"

    if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        log_info "Resource group '$RESOURCE_GROUP' already exists"
    else
        log_info "Creating resource group: $RESOURCE_GROUP in $LOCATION"
        az group create \
            --name "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --tags $TAGS
        log_success "Resource group created"
    fi
}

# Create storage account
create_storage_account() {
    log_info "Checking storage account: $STORAGE_ACCOUNT_NAME"

    if az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        log_warning "Storage account '$STORAGE_ACCOUNT_NAME' already exists"
    else
        log_info "Creating storage account: $STORAGE_ACCOUNT_NAME"
        
        local public_network_access="Enabled"
        if [[ "$DISABLE_PUBLIC_ACCESS" == "true" ]]; then
            public_network_access="Disabled"
        fi

        # Note: --allow-blob-public-access and --allow-shared-key-access may be overridden
        # by Azure Policy. The script uses Azure AD auth (--auth-mode login) as fallback.
        az storage account create \
            --name "$STORAGE_ACCOUNT_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --sku "$SKU" \
            --kind StorageV2 \
            --access-tier Hot \
            --https-only true \
            --min-tls-version TLS1_2 \
            --allow-blob-public-access true \
            --allow-shared-key-access true \
            --public-network-access "$public_network_access" \
            --tags $TAGS

        log_success "Storage account created"
    fi
}

# Assign Storage Blob Data Contributor role to current user
assign_storage_role() {
    log_info "Assigning Storage Blob Data Contributor role to current user..."

    local storage_id
    storage_id=$(az storage account show \
        --name "$STORAGE_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query 'id' -o tsv)

    local user_id
    user_id=$(az ad signed-in-user show --query id -o tsv 2>/dev/null) || true

    if [[ -n "$user_id" ]]; then
        # Check if role assignment already exists
        local existing_assignment
        existing_assignment=$(az role assignment list \
            --assignee "$user_id" \
            --scope "$storage_id" \
            --role "Storage Blob Data Contributor" \
            --query '[0].id' -o tsv 2>/dev/null) || true

        if [[ -n "$existing_assignment" ]]; then
            log_info "Storage Blob Data Contributor role already assigned"
        else
            az role assignment create \
                --role "Storage Blob Data Contributor" \
                --assignee "$user_id" \
                --scope "$storage_id" > /dev/null
            log_success "Storage Blob Data Contributor role assigned"
            
            # Wait for RBAC propagation
            log_info "Waiting for RBAC propagation (30 seconds)..."
            sleep 30
        fi
    else
        log_warning "Could not determine current user ID, skipping role assignment"
        log_warning "You may need to manually assign Storage Blob Data Contributor role"
    fi
}

# Create blob container
create_container() {
    log_info "Creating blob container: $CONTAINER_NAME"

    # Use Azure AD authentication (--auth-mode login) which works even when
    # shared key access is disabled by Azure Policy
    if az storage container show \
        --name "$CONTAINER_NAME" \
        --account-name "$STORAGE_ACCOUNT_NAME" \
        --auth-mode login &> /dev/null; then
        log_info "Container '$CONTAINER_NAME' already exists"
    else
        # Try with public access first, fall back to private if Azure Policy blocks it
        if ! az storage container create \
            --name "$CONTAINER_NAME" \
            --account-name "$STORAGE_ACCOUNT_NAME" \
            --auth-mode login \
            --public-access blob 2>/dev/null; then
            
            log_warning "Public blob access may be disabled by Azure Policy, creating private container"
            az storage container create \
                --name "$CONTAINER_NAME" \
                --account-name "$STORAGE_ACCOUNT_NAME" \
                --auth-mode login
            
            log_info "Container created without public access - Azure AD authentication will be used"
        else
            log_success "Container created with public blob access"
        fi
    fi

    # Create directory structure for RPM repository
    log_info "Creating RPM repository directory structure..."
    
    # Create placeholder files for directory structure using Azure AD auth
    for dir in "el8/x86_64/Packages" "el8/x86_64/repodata" "el9/x86_64/Packages" "el9/x86_64/repodata"; do
        echo "RPM Repository - $dir" | az storage blob upload \
            --container-name "$CONTAINER_NAME" \
            --name "$dir/.placeholder" \
            --account-name "$STORAGE_ACCOUNT_NAME" \
            --auth-mode login \
            --data @- \
            --overwrite &> /dev/null || true
    done

    log_success "RPM repository directory structure created"
}

# Create private endpoint
create_private_endpoint() {
    if [[ "$ENABLE_PRIVATE_ENDPOINT" != "true" ]]; then
        log_info "Skipping private endpoint creation (disabled)"
        return
    fi

    log_info "Creating private endpoint: $PRIVATE_ENDPOINT_NAME"

    # Get storage account resource ID
    local storage_id
    storage_id=$(az storage account show \
        --name "$STORAGE_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query 'id' -o tsv)

    # Get subnet resource ID
    local subnet_id
    subnet_id=$(az network vnet subnet show \
        --name "$SUBNET_NAME" \
        --vnet-name "$VNET_NAME" \
        --resource-group "$VNET_RESOURCE_GROUP" \
        --query 'id' -o tsv)

    # Check if private endpoint already exists
    if az network private-endpoint show \
        --name "$PRIVATE_ENDPOINT_NAME" \
        --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        log_warning "Private endpoint '$PRIVATE_ENDPOINT_NAME' already exists"
    else
        # Disable network policies on subnet if needed
        log_info "Configuring subnet for private endpoint..."
        az network vnet subnet update \
            --name "$SUBNET_NAME" \
            --vnet-name "$VNET_NAME" \
            --resource-group "$VNET_RESOURCE_GROUP" \
            --disable-private-endpoint-network-policies true

        # Create private endpoint
        az network private-endpoint create \
            --name "$PRIVATE_ENDPOINT_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$VNET_NAME" \
            --subnet "$SUBNET_NAME" \
            --private-connection-resource-id "$storage_id" \
            --group-id blob \
            --connection-name "${STORAGE_ACCOUNT_NAME}-connection" \
            --location "$LOCATION" \
            --tags $TAGS

        log_success "Private endpoint created"
    fi

    # Create private DNS zone and link
    create_private_dns_zone
}

# Create private DNS zone for blob storage
create_private_dns_zone() {
    local dns_zone_name="privatelink.blob.core.windows.net"
    local dns_link_name="${VNET_NAME}-link"

    log_info "Configuring private DNS zone: $dns_zone_name"

    # Create private DNS zone if it doesn't exist
    if ! az network private-dns zone show \
        --name "$dns_zone_name" \
        --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        
        az network private-dns zone create \
            --name "$dns_zone_name" \
            --resource-group "$RESOURCE_GROUP" \
            --tags $TAGS

        log_success "Private DNS zone created"
    else
        log_info "Private DNS zone already exists"
    fi

    # Link DNS zone to VNet if not already linked
    if ! az network private-dns link vnet show \
        --name "$dns_link_name" \
        --zone-name "$dns_zone_name" \
        --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        
        local vnet_id
        vnet_id=$(az network vnet show \
            --name "$VNET_NAME" \
            --resource-group "$VNET_RESOURCE_GROUP" \
            --query 'id' -o tsv)

        az network private-dns link vnet create \
            --name "$dns_link_name" \
            --zone-name "$dns_zone_name" \
            --resource-group "$RESOURCE_GROUP" \
            --virtual-network "$vnet_id" \
            --registration-enabled false \
            --tags $TAGS

        log_success "Private DNS zone linked to VNet"
    else
        log_info "Private DNS zone link already exists"
    fi

    # Create DNS zone group for automatic DNS registration
    local dns_zone_group_name="${PRIVATE_ENDPOINT_NAME}-dnszonegroup"
    
    if ! az network private-endpoint dns-zone-group show \
        --name "$dns_zone_group_name" \
        --endpoint-name "$PRIVATE_ENDPOINT_NAME" \
        --resource-group "$RESOURCE_GROUP" &> /dev/null; then

        local dns_zone_id
        dns_zone_id=$(az network private-dns zone show \
            --name "$dns_zone_name" \
            --resource-group "$RESOURCE_GROUP" \
            --query 'id' -o tsv)

        az network private-endpoint dns-zone-group create \
            --name "$dns_zone_group_name" \
            --endpoint-name "$PRIVATE_ENDPOINT_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --private-dns-zone "$dns_zone_id" \
            --zone-name "blob"

        log_success "DNS zone group created for automatic DNS registration"
    else
        log_info "DNS zone group already exists"
    fi
}

# Show setup summary and save configuration
show_summary() {
    echo ""
    log_success "Storage account setup complete!"
    echo ""
    echo "=============================================="
    echo "Storage Account Details"
    echo "=============================================="
    echo "Resource Group:    $RESOURCE_GROUP"
    echo "Storage Account:   $STORAGE_ACCOUNT_NAME"
    echo "Container:         $CONTAINER_NAME"
    echo "Location:          $LOCATION"
    echo ""
    echo "Blob Endpoint:     https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net"
    echo "Repository URL:    https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${CONTAINER_NAME}"
    echo ""
    
    if [[ "$ENABLE_PRIVATE_ENDPOINT" == "true" ]]; then
        echo "Private Endpoint:  $PRIVATE_ENDPOINT_NAME"
        echo "Private DNS Zone:  privatelink.blob.core.windows.net"
        echo ""
    fi

    echo "=============================================="
    echo "Authentication: Azure AD (RBAC)"
    echo "=============================================="
    echo "Required Role (uploads):  Storage Blob Data Contributor"
    echo "Required Role (clients):  Storage Blob Data Reader"
    echo ""
    echo "=============================================="
    echo "Client Configuration"
    echo "=============================================="
    echo ""
    echo "1. Install dnf-plugin-azure-auth RPM on clients:"
    echo "   dnf install dnf-plugin-azure-auth azure-cli"
    echo ""
    echo "2. Login to Azure (or use Managed Identity on Azure VMs):"
    echo "   az login"
    echo "   # OR for Managed Identity:"
    echo "   az login --identity"
    echo ""
    echo "3. Configure the plugin (/etc/dnf/plugins/azure_auth.conf):"
    echo "   [azure-rpm-repo]"
    echo ""
    echo "4. Create repo file (/etc/yum.repos.d/azure-rpm.repo):"
    echo "   [azure-rpm-repo]"
    echo "   name=Azure RPM Repository"
    echo "   baseurl=https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${CONTAINER_NAME}/el9/x86_64"
    echo "   enabled=1"
    echo "   gpgcheck=0"
    echo ""
    echo "5. Assign 'Storage Blob Data Reader' role to clients:"
    echo "   az role assignment create --role 'Storage Blob Data Reader' \\"
    echo "     --assignee <client-principal-id> \\"
    echo "     --scope /subscriptions/.../storageAccounts/${STORAGE_ACCOUNT_NAME}"
    echo ""
    echo "=============================================="
    echo "Environment Variables"
    echo "=============================================="
    echo "AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT_NAME"
    echo "AZURE_STORAGE_CONTAINER=$CONTAINER_NAME"
    echo "AZURE_RESOURCE_GROUP=$RESOURCE_GROUP"
    echo "AZURE_BLOB_BASE_URL=https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${CONTAINER_NAME}"
    echo ""

    # Save to env file
    local env_file="/mnt/c/dev/rpm-poc/.env.generated"
    cat > "$env_file" << EOF
# Generated Azure Storage Configuration (Azure AD Authentication)
# Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Authentication: Azure AD with RBAC roles (no SAS tokens)

AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT_NAME
AZURE_STORAGE_CONTAINER=$CONTAINER_NAME
AZURE_RESOURCE_GROUP=$RESOURCE_GROUP
AZURE_BLOB_BASE_URL=https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${CONTAINER_NAME}
LOCATION=$LOCATION

# Repository paths
REPO_PATH=el9/x86_64
EL8_REPO_PATH=el8/x86_64
EL9_REPO_PATH=el9/x86_64
EOF

    log_success "Configuration saved to: $env_file"
}

# Main execution
main() {
    echo ""
    echo "=============================================="
    echo "Azure Storage Account Setup for RPM Repository"
    echo "=============================================="
    echo ""

    parse_args "$@"
    validate_params
    check_prerequisites
    create_resource_group
    create_storage_account
    assign_storage_role
    create_container
    create_private_endpoint
    show_summary

    echo ""
    log_success "Setup completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Copy the environment variables to your .env file"
    echo "2. Run the RPM build and upload script:"
    echo "   ./scripts/docker-build-and-upload.sh"
    echo "3. Test the repository:"
    echo "   ./scripts/test-repository.sh"
    echo ""
}

# Run main function
main "$@"
