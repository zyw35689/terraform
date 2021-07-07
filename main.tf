###################    Configure the Azure provider    ########################
  terraform {
    required_providers {
      azurerm = {
        source  = "hashicorp/azurerm"
        version = ">= 2.26"
      }
    }

    required_version = ">= 0.14.9"
  }

  provider "azurerm" {
    features {}
  }

######################    CREATE ** RESOURCE    ###############################

  # define prefix
  variable "prefix" {
    default = "tfdemo"
  }

  # create RG
  resource "azurerm_resource_group" "rg" {
    name     = "${var.prefix}_RG"
    location = "East Asia"
  }

  # create network
  resource "azurerm_virtual_network" "vnet" {
    name                = "${var.prefix}-vnet"
    address_space       = ["10.0.0.0/16"]
    location            = azurerm_resource_group.rg.location
    resource_group_name = azurerm_resource_group.rg.name
  }

  # create subnet
  resource "azurerm_subnet" "sub" {
    name                 = "${var.prefix}-subnet"
    address_prefixes     = ["10.0.0.0/24"]
    resource_group_name  = azurerm_resource_group.rg.name
    virtual_network_name = azurerm_virtual_network.vnet.name
    enforce_private_link_service_network_policies = true
  }

  # create interface
  resource "azurerm_network_interface" "int01" {
    name                = "${var.prefix}-nic1"
    location            = azurerm_resource_group.rg.location
    resource_group_name = azurerm_resource_group.rg.name

    # config intcfg
    ip_configuration {
      name= "ipcfg"
      subnet_id=azurerm_subnet.sub.id
      private_ip_address_allocation= "Dynamic"
    }
  }

  # create vm
  resource "azurerm_virtual_machine" "vm01" {
    name                  = "${var.prefix}-vm01"
    location              = azurerm_resource_group.rg.location
    resource_group_name   = azurerm_resource_group.rg.name
    network_interface_ids = [azurerm_network_interface.int01.id]
    vm_size               = "Standard_DS1_v2"

    # Uncomment this line to delete the OS/data disk automatically when deleting the vm
      delete_os_disk_on_termination = true
      delete_data_disks_on_termination = true
    
    # config image
    storage_image_reference {
      publisher = "Canonical"
      offer     = "UbuntuServer"
      sku       = "16.04-LTS"
      version   = "latest"
    }

    # config os
    storage_os_disk {
      name              = "{azurerm_virtual_machine.vm01.name}-osdisk"
      caching           = "ReadWrite"
      create_option     = "FromImage"
      managed_disk_type = "Standard_LRS"
    }

    # config authentication
    os_profile {
      computer_name  = "tfdemo"
      admin_username = "demo01"
      admin_password = "P@ssw0rd!123"
    }

    # config linux allow passwd
    os_profile_linux_config {
      disable_password_authentication = false
    }
  }

  # create storageaccount
  resource "azurerm_storage_account" "sa" {
    name                     = "${var.prefix}account"
    resource_group_name      = azurerm_resource_group.rg.name
    location                 = azurerm_resource_group.rg.location
    account_tier             = "Standard"
    access_tier              = "cool"
    account_replication_type = "ZRS"
    large_file_share_enabled = true
  }

  resource "azurerm_storage_account" "sqlsa" {
    name                     = "sqlsa"
    resource_group_name      = azurerm_resource_group.rg.name
    location                 = azurerm_resource_group.rg.location
    account_tier             = "Standard"
    account_replication_type = "LRS"
  }

  # create azurefile
  resource "azurerm_storage_share" "afs" {
    name                 = "example-share"
    storage_account_name = azurerm_storage_account.sa.name
  }

  # create sqlserver
  resource "azurerm_mssql_server" "sql" {
    name                         = "${var.prefix}"
    resource_group_name          = azurerm_resource_group.rg.name
    location                     = azurerm_resource_group.rg.location
    version                      = "12.0"
    administrator_login          = "sqladmin"
    administrator_login_password = "P@ssw0rd!1234"
  }

  # create sqldb
  resource "azurerm_mssql_database" "sqldb" {
    name                 = "${var.prefix}-db"
    server_id            = azurerm_mssql_server.sql.id
    collation            = "SQL_Latin1_General_CP1_CI_AS"
    license_type         = "LicenseIncluded"
    max_size_gb          = 4
    read_scale           = true
    sku_name             = "BC_Gen5_2"
    zone_redundant       = true
    storage_account_type = "GRS"

    extended_auditing_policy {
      storage_endpoint                        = azurerm_storage_account.sqlsa.primary_blob_endpoint
      storage_account_access_key              = azurerm_storage_account.sqlsa.primary_access_key
      storage_account_access_key_is_secondary = true
      retention_in_days                       = 6
    }
  }

  # create recovery vault 
  resource "azurerm_recovery_services_vault" "vault" {
    name                = "${var.prefix}vault"
    location            = azurerm_resource_group.rg.location
    resource_group_name = azurerm_resource_group.rg.name
    sku                 = "Standard"

    soft_delete_enabled = true
  }

  # create backup-policy
  resource "azurerm_backup_policy_file_share" "policy" {
    name                = "tfex-recovery-vault-policy"
    resource_group_name = azurerm_resource_group.rg.name
    recovery_vault_name = azurerm_recovery_services_vault.vault.name

    timezone = "UTC"

    backup {
      frequency = "Daily"
      time      = "23:00"
    }

    retention_daily {
      count = 10
    }

    retention_weekly {
      count    = 7
      weekdays = ["Sunday", "Wednesday", "Friday", "Saturday"]
    }

    retention_monthly {
      count    = 7
      weekdays = ["Sunday", "Wednesday"]
      weeks    = ["First", "Last"]
    }

    retention_yearly {
      count    = 7
      weekdays = ["Sunday"]
      weeks    = ["Last"]
      months   = ["January"]
    }
  }

  # create fileshare backup
  resource "azurerm_backup_protected_file_share" "fbk" {
    resource_group_name       = azurerm_resource_group.rg.name
    recovery_vault_name       = azurerm_recovery_services_vault.vault.name
    source_storage_account_id = azurerm_storage_account.sa.id
    source_file_share_name    = azurerm_storage_share.afs.name
    backup_policy_id          = azurerm_backup_policy_file_share.policy.id
  }

  #create endpoint 
  resource "azurerm_private_endpoint" "pe" {
    name                 = "${var.prefix}-pe"
    location             = azurerm_resource_group.rg.location
    resource_group_name  = azurerm_resource_group.rg.name
    subnet_id            = azurerm_subnet.sub.id

    private_service_connection {
      name                           = "sql-connection"
      is_manual_connection           = false
      private_connection_resource_id = azurerm_mssql_database.sqldb.id
      subresource_names              = [azurerm_mssql_database.sqldb.name]
    }
  }
