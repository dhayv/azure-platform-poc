resource "random_string" "shortid" {
  length  = 4
  upper   = false
  special = false
  numeric = true
}

resource "random_pet" "suffix" {
  length = 2
}

locals {
  project = "aks-platform-poc"
  env     = "dev"
  suffix  = random_pet.suffix.id
  shortid = random_string.shortid.result

  rg_name         = "rg-${local.project}-${local.env}"
  aks_name        = "aks-${local.project}-${local.env}"
  aks_dns_prefix  = "dns-${local.project}-${local.env}"
  acr_name        = replace("acr${local.project}${local.env}${local.shortid}", "-", "")
  monitor_ws_name = "amw-${local.project}-${local.env}"
  grafana_name    = "graf-${local.env}-${local.shortid}"
  msprom_prefix   = "MSProm-${local.env}-${local.project}"

  tags = {
    project     = local.project
    environment = local.env
    owner       = "OpsTeam"
    managed_by  = "terraform"
  }
}



resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = var.resource_group_location
  tags     = local.tags
}




resource "azurerm_kubernetes_cluster" "aks" {
  name                = local.aks_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = local.aks_dns_prefix
  oidc_issuer_enabled = true

  default_node_pool {
    name       = "sysmpool"
    node_count = var.node_count
    vm_size    = "Standard_D2ds_v4"

    auto_scaling_enabled = true
    min_count            = 1
    max_count            = 2
    type                 = "VirtualMachineScaleSets"

    os_disk_type    = "Ephemeral"
    os_disk_size_gb = 60
  }


  monitor_metrics {
    annotations_allowed = "prometheus.io/scrape,prometheus.io/path,prometheus.io/port"
    labels_allowed      = "app,tier"
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.law.id
    msi_auth_for_monitoring_enabled = true
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags

}


resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "userpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = "Standard_D2ds_v4"
  mode                  = "User"

  auto_scaling_enabled = true
  min_count            = 1
  max_count            = 3

  os_disk_type    = "Ephemeral"
  os_disk_size_gb = 60

  node_labels = {
    workload = "apps"
  }

  tags = local.tags
}

resource "azurerm_container_registry" "acr" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id

}

# #region Managed Prometheus setup
# Refer https://github.com/Azure/prometheus-collector/blob/main/AddonTerraformTemplate/main.tf

# Azure Monitor Workspace for managed Prometheus metrics
resource "azurerm_monitor_workspace" "prometheus" {
  name                = local.monitor_ws_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = local.tags
}


resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                = substr("${local.msprom_prefix}-dce", 0, 44)
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  kind                = "Linux"
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = substr("${local.msprom_prefix}-dcr", 0, 64)
  resource_group_name         = azurerm_resource_group.rg.name
  location                    = azurerm_resource_group.rg.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
  kind                        = "Linux"
  description                 = "DCR for AKS managed Prometheus metrics"

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.prometheus.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      streams = ["Microsoft-PrometheusMetrics"]
      name    = "PrometheusDataSource"
    }
  }

  tags = local.tags
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${local.project}-${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.tags
}

resource "azurerm_monitor_data_collection_rule_association" "prometheus" {
  name                    = substr("${local.msprom_prefix}-assoc", 0, 64)
  target_resource_id      = azurerm_kubernetes_cluster.aks.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
  description             = "Association of managed Prometheus DCR to AKS cluster."

}


resource "azurerm_dashboard_grafana" "grafana" {
  name                          = local.grafana_name
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  grafana_major_version         = "12"
  public_network_access_enabled = true
  sku                           = "Standard"

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.prometheus.id
  }

  tags = local.tags
}

resource "azurerm_role_assignment" "grafana_monitor_data_reader" {
  scope                = azurerm_monitor_workspace.prometheus.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.grafana.identity[0].principal_id

}
