#!/usr/bin/env bash
set -euo pipefail

required_commands=(az dotnet func)
for command_name in "${required_commands[@]}"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Missing required command: ${command_name}" >&2
        exit 1
    fi
done

required_variables=(
    AZURE_RESOURCE_GROUP
    AZURE_LOCATION
    AZURE_FUNCTION_APP
    AZURE_STORAGE_ACCOUNT
    POKER_SQL_CONNECTION_STRING
    WORDPRESS_ORIGIN
)
for variable_name in "${required_variables[@]}"; do
    if [[ -z "${!variable_name:-}" ]]; then
        echo "Missing required environment variable: ${variable_name}" >&2
        exit 1
    fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
function_project="$(cd "${script_dir}/../azure-function" && pwd)"

az group create \
    --name "${AZURE_RESOURCE_GROUP}" \
    --location "${AZURE_LOCATION}" \
    --output none

if ! az storage account show \
    --name "${AZURE_STORAGE_ACCOUNT}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --output none 2>/dev/null; then
    az storage account create \
        --name "${AZURE_STORAGE_ACCOUNT}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --location "${AZURE_LOCATION}" \
        --sku Standard_LRS \
        --output none
fi

if ! az functionapp show \
    --name "${AZURE_FUNCTION_APP}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --output none 2>/dev/null; then
    az functionapp create \
        --name "${AZURE_FUNCTION_APP}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --storage-account "${AZURE_STORAGE_ACCOUNT}" \
        --flexconsumption-location "${AZURE_LOCATION}" \
        --runtime dotnet-isolated \
        --runtime-version 10.0 \
        --output none
fi

az functionapp config appsettings set \
    --name "${AZURE_FUNCTION_APP}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --settings \
        "PokerSqlConnectionString=${POKER_SQL_CONNECTION_STRING}" \
        "PokerCacheSeconds=10" \
        "PokerCommandTimeoutSeconds=20" \
    --output none

if ! az functionapp cors show \
    --name "${AZURE_FUNCTION_APP}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --query "allowedOrigins[?@=='${WORDPRESS_ORIGIN}'] | [0]" \
    --output tsv | grep -Fqx "${WORDPRESS_ORIGIN}"; then
    az functionapp cors add \
        --name "${AZURE_FUNCTION_APP}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --allowed-origins "${WORDPRESS_ORIGIN}" \
        --output none
fi

(
    cd "${function_project}"
    func azure functionapp publish "${AZURE_FUNCTION_APP}" --dotnet-version 10.0
)

endpoint="https://${AZURE_FUNCTION_APP}.azurewebsites.net/api/poker/state"
echo
echo "Deployment complete. Test:"
echo "curl --fail --show-error '${endpoint}'"
echo
echo "WordPress wp-config.php setting:"
echo "define('TEXAS_HOLDEM_API_URL', '${endpoint}');"
