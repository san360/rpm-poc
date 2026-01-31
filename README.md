# Azure Blob Storage RPM Repository POC

## Overview

This repository provides a complete solution for hosting RPM packages on Azure Blob Storage using **Azure AD authentication** (no SAS tokens). It includes:

- **dnf-plugin-azure-auth**: A DNF/YUM plugin that automatically injects Azure AD tokens for repository access
- **Build scripts**: Local RPM building on Debian/Ubuntu or RHEL-based systems
- **Azure infrastructure scripts**: Create storage accounts with proper RBAC configuration

## Repository Structure

```
rpm-poc/
├── README.md                           # This file
├── QUICKSTART.md                       # Step-by-step testing guide
├── RPM-Azure-Implementation.md         # Comprehensive implementation guide
├── azure-pipelines.yml                 # Azure DevOps CI/CD pipeline
├── docker-compose.yml                  # Docker test environment
├── Dockerfile.rpm-builder              # Docker image for building RPMs
├── scripts/
│   ├── create-azure-storage.sh         # Create Azure Storage with RBAC
│   ├── build-rpm-local.sh              # Local RPM build script
│   ├── upload-to-azure.sh              # Upload to Azure Blob (Azure AD)
│   ├── test-repository.sh              # Repository test script
│   └── e2e-test.sh                     # End-to-end test script
├── config/
│   └── azure-blob.repo.template        # Repository configuration template
├── sources/
│   ├── azure_auth.py                   # DNF Azure AD auth plugin source
│   └── azure_auth.conf                 # Plugin configuration template
├── packages/                           # Built RPM packages (generated)
└── specs/
    ├── hello-azure.spec                # Sample test RPM spec
    └── dnf-plugin-azure-auth.spec      # Azure AD auth plugin spec
```

## Quick Start

### Prerequisites

```bash
# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Login to Azure
az login

# Install build tools (Debian/Ubuntu)
sudo apt-get update && sudo apt-get install -y rpm createrepo-c
```

### Build and Deploy

```bash
# 1. Build RPM packages (including dnf-plugin-azure-auth)
./scripts/build-rpm-local.sh all

# 2. Create Azure storage with RBAC
./scripts/create-azure-storage.sh -g rg-rpm-poc

# 3. Upload packages (uses Azure AD automatically)
source .env.generated
./scripts/upload-to-azure.sh

# 4. Test the repository
./scripts/test-repository.sh -s $AZURE_STORAGE_ACCOUNT
```

### Client Configuration

On systems that need to access the repository:

```bash
# 1. Install the plugin (azure-cli is optional but recommended)
sudo dnf install dnf-plugin-azure-auth

# 2. Authentication Options:
#    Option A: Use Azure CLI (recommended for interactive systems)
sudo dnf install azure-cli
az login                      # Interactive login
# OR
az login --identity           # Managed Identity (Azure VMs)

#    Option B: Use pre-generated token (for bootstrapping/containers)
export DNF_PLUGIN_AZURE_AUTH_TOKEN="<your-azure-ad-token>"

# 3. Configure the plugin (/etc/dnf/plugins/azure_auth.conf)
sudo tee -a /etc/dnf/plugins/azure_auth.conf << 'EOF'
[azure-rpm-repo]
EOF

# 4. Create repo file (/etc/yum.repos.d/azure-rpm.repo)
sudo tee /etc/yum.repos.d/azure-rpm.repo << 'EOF'
[azure-rpm-repo]
name=Azure Blob RPM Repository
baseurl=https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/rpm-repo/el9/x86_64
enabled=1
gpgcheck=0
EOF

# 5. Test
sudo dnf makecache
sudo dnf install hello-azure
```

## Authentication

This solution uses **Azure AD authentication exclusively**. No SAS tokens or storage keys are required.

### How It Works

1. **dnf-plugin-azure-auth** intercepts repository requests to Azure Blob Storage URLs
2. The plugin obtains an Azure AD token using `az account get-access-token`
3. Requests are modified to include `Authorization: Bearer <token>` header
4. Azure Blob Storage validates the token and serves the content

### RBAC Requirements

| Role | Purpose |
|------|---------|
| **Storage Blob Data Contributor** | Upload packages (CI/CD, administrators) |
| **Storage Blob Data Reader** | Download packages (client systems) |

### Assigning Roles

```bash
# For users
az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee user@example.com \
  --scope /subscriptions/SUBSCRIPTION_ID/resourceGroups/RG/providers/Microsoft.Storage/storageAccounts/ACCOUNT

# For Azure VMs with Managed Identity
VM_PRINCIPAL_ID=$(az vm show -g RG -n VM --query identity.principalId -o tsv)
az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee-object-id $VM_PRINCIPAL_ID \
  --scope /subscriptions/SUBSCRIPTION_ID/resourceGroups/RG/providers/Microsoft.Storage/storageAccounts/ACCOUNT

# For Service Principals
az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee SP_APP_ID \
  --scope /subscriptions/SUBSCRIPTION_ID/resourceGroups/RG/providers/Microsoft.Storage/storageAccounts/ACCOUNT
```

## CI/CD Integration

For CI/CD pipelines where Azure CLI may not be available, use pre-generated tokens:

```bash
# Generate token (valid ~1 hour)
TOKEN=$(az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)

# Pass to build agents via environment variable
export DNF_PLUGIN_AZURE_AUTH_TOKEN="$TOKEN"

# The plugin will use this token instead of calling az cli
dnf install -y hello-azure
```

## Testing

### Run All Tests

```bash
./scripts/e2e-test.sh -g rg-rpm-poc
```

### Test Individual Components

```bash
# Test repository access
./scripts/test-repository.sh -s rpmrepopoc12345 -v

# Test with Docker
docker run --rm -it \
  -e DNF_PLUGIN_AZURE_AUTH_TOKEN="$(az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)" \
  -v $(pwd)/packages:/packages:ro \
  rockylinux:9 bash -c "
    dnf install -y /packages/dnf-plugin-azure-auth-*.rpm
    echo '[azure-rpm-repo]' >> /etc/dnf/plugins/azure_auth.conf
    echo '[azure-rpm-repo]
name=Azure RPM Repository
baseurl=https://STORAGE_ACCOUNT.blob.core.windows.net/rpm-repo/el9/x86_64
enabled=1
gpgcheck=0' > /etc/yum.repos.d/azure.repo
    dnf makecache
"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `403 Forbidden` | Verify RBAC role assignment (`Storage Blob Data Reader`) |
| `Failed to get Azure AD token` | Run `az login` or check Managed Identity configuration |
| `repomd.xml not found` | Ensure repository metadata was uploaded |
| `Could not resolve host` | Verify storage account name |
| `Azure Policy blocking settings` | This solution uses Azure AD auth, compatible with enterprise policies |
| `Token expired` | Tokens are valid ~1 hour; plugin refreshes automatically |

## Documentation

- [Quick Start Guide](QUICKSTART.md) - Step-by-step setup
- [Implementation Guide](RPM-Azure-Implementation.md) - Detailed architecture and configuration

## References

- [dnf-plugin-azure-auth (Metaswitch)](https://github.com/Metaswitch/dnf-plugin-azure-auth)
- [Azure Blob Storage Authentication](https://learn.microsoft.com/azure/storage/blobs/authorize-access-azure-active-directory)
- [Azure RBAC for Storage](https://learn.microsoft.com/azure/storage/common/storage-auth-aad-rbac-portal)

## License

This POC is provided for educational and testing purposes.
