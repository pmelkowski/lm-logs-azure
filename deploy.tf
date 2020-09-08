variable "lm_company_name" {
  description = "LogicMonitor company name"
}

variable "lm_access_id" {
  description = "LogicMonitor access id"
}

variable "lm_access_key" {
  description = "LogicMonitor access key"
}

variable "azure_region" {
  description = "Azure region"
}

variable "package_file" {
  description = "Azure function ZIP package"
  default = "./package/lm-logs-azure.zip"
}

locals {
  namespace = "lm-logs-${var.lm_company_name}-${var.azure_region}"
  storage = lower(replace(replace(local.namespace, "2", "two"), "/[^A-Za-z]+/", ""))
}

provider "azurerm" {
  version = ">= 2.0.0"
  features {}
}

resource "azurerm_resource_group" "lm_logs" {
  name = "${local.namespace}-group"
  location = var.azure_region
}

resource "azurerm_eventhub_namespace" "lm_logs" {
  name                = local.namespace
  resource_group_name = azurerm_resource_group.lm_logs.name
  location            = var.azure_region
  sku                 = "Standard"
  capacity            = 1
}

resource "azurerm_eventhub" "lm_logs" {
  name                = "log-hub"
  resource_group_name = azurerm_resource_group.lm_logs.name
  namespace_name      = azurerm_eventhub_namespace.lm_logs.name
  partition_count     = 1
  message_retention   = 1
}

resource "azurerm_eventhub_authorization_rule" "lm_logs_sender" {
  name                = "sender"
  resource_group_name = azurerm_resource_group.lm_logs.name
  namespace_name      = azurerm_eventhub_namespace.lm_logs.name
  eventhub_name       = azurerm_eventhub.lm_logs.name
  listen              = false
  send                = true
  manage              = false
}

resource "azurerm_eventhub_authorization_rule" "lm_logs_listener" {
  name                = "listener"
  resource_group_name = azurerm_resource_group.lm_logs.name
  namespace_name      = azurerm_eventhub_namespace.lm_logs.name
  eventhub_name       = azurerm_eventhub.lm_logs.name
  listen              = true
  send                = false
  manage              = false
}

resource "azurerm_storage_account" "lm_logs" {
  name                     = length(local.storage) > 24 ? substr(local.storage, length(local.storage) - 24, 24) : local.storage
  resource_group_name      = azurerm_resource_group.lm_logs.name
  location                 = var.azure_region
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "lm_logs" {
  name                  = "package"
  storage_account_name  = azurerm_storage_account.lm_logs.name
  container_access_type = "private"
}

resource "azurerm_storage_blob" "lm_logs" {
  name                   = "lm-logs-azure.zip"
  storage_account_name   = azurerm_storage_account.lm_logs.name
  storage_container_name = azurerm_storage_container.lm_logs.name
  type                   = "Block"
  source                 = var.package_file
}

data "azurerm_storage_account_sas" "sas" {
  connection_string = azurerm_storage_account.lm_logs.primary_connection_string
  https_only        = true
  start             = formatdate("YYYY-MM-DD", timestamp())
  expiry            = formatdate("YYYY-MM-DD", timeadd(timestamp(), "87600h")) # + 10 years
  resource_types {
    object    = true
    container = false
    service   = false
  }
  services {
    blob      = true
    queue     = false
    table     = false
    file      = false
  }
  permissions {
    read      = true
    write     = false
    delete    = false
    list      = false
    add       = false
    create    = false
    update    = false
    process   = false
  }
}

resource "azurerm_app_service_plan" "lm_logs" {
  name                = "${local.namespace}-service-plan"
  resource_group_name = azurerm_resource_group.lm_logs.name
  location            = var.azure_region
  kind                = "FunctionApp"
  reserved            = true
  sku {
    tier = "Standard"
    size = "S1"
  }
}

resource "azurerm_function_app" "lm_logs" {
  name                       = local.namespace
  resource_group_name        = azurerm_resource_group.lm_logs.name
  location                   = var.azure_region
  app_service_plan_id        = azurerm_app_service_plan.lm_logs.id
  storage_account_name       = azurerm_storage_account.lm_logs.name
  storage_account_access_key = azurerm_storage_account.lm_logs.primary_access_key
  os_type                    = "linux"
  https_only                 = true
  version                    = "~3"
  site_config {
    always_on                = true
    linux_fx_version         = "java|11"
  }
  app_settings = {
    FUNCTIONS_WORKER_RUNTIME     = "java"
    FUNCTIONS_EXTENSION_VERSION  = "~3"
    HASH                         = base64encode(filesha256(var.package_file))
    WEBSITE_RUN_FROM_PACKAGE     = "https://${azurerm_storage_account.lm_logs.name}.blob.core.windows.net/${azurerm_storage_container.lm_logs.name}/${azurerm_storage_blob.lm_logs.name}${data.azurerm_storage_account_sas.sas.sas}"
    LogsEventHubConnectionString = azurerm_eventhub_authorization_rule.lm_logs_listener.primary_connection_string
    LogicMonitorCompanyName      = var.lm_company_name
    LogicMonitorAccessId         = var.lm_access_id
    LogicMonitorAccessKey        = var.lm_access_key
#    LogApiClientConnectTimeout   = 10000
#    LogApiClientReadTimeout      = 10000
#    LogApiClientDebugging        = false
#    LogRegexScrub                = "\\d+\\.\\d+\\.\\d+\\.\\d+"
  }
}

