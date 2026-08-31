# 노드 하나. VM · NIC · 데이터 디스크를 묶는다.
#

# 공인 IP 는 ops 노드에만 붙는다. 서비스 노드는 사설 IP 로만 접근한다.
# 관측 도구가 관측 대상과 같은 경로로 노출되면 장애 실습이 성립하지 않는다.
resource "azurerm_public_ip" "this" {
  count = var.public_ip ? 1 : 0

  name                = "${var.name}-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zone == null ? null : [var.zone]
  tags                = var.tags
}

resource "azurerm_network_interface" "this" {
  name                = "${var.name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = var.private_ip == null ? "Dynamic" : "Static"
    private_ip_address            = var.private_ip
    public_ip_address_id          = var.public_ip ? azurerm_public_ip.this[0].id : null
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = var.name
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.size
  zone                            = var.zone
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this.id]
  tags                            = var.tags

  custom_data = var.custom_data == null ? null : base64encode(var.custom_data)

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  # ops 노드가 서비스 노드에 붙을 때 쓰는 실습용 키.
  # 수강생 키는 ops 접속용이고, 서비스 노드에는 공인 IP 가 없어 ops 를 거쳐야 한다.
  dynamic "admin_ssh_key" {
    for_each = var.extra_ssh_public_key == null ? [] : [var.extra_ssh_public_key]
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = var.image.publisher
    offer     = var.image.offer
    sku       = var.image.sku
    version   = var.image.version
  }
}

# 데이터 디스크는 Premium SSD v2 다. 용량·IOPS·처리량을 따로 정할 수 있다.
resource "azurerm_managed_disk" "data" {
  count = var.data_disk_gb > 0 ? 1 : 0

  name                 = "${var.name}-data"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "PremiumV2_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_gb
  disk_iops_read_write = 3000
  disk_mbps_read_write = 125
  zone                 = var.zone
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  count = var.data_disk_gb > 0 ? 1 : 0

  managed_disk_id    = azurerm_managed_disk.data[0].id
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  lun                = 0
  caching            = "None"
}
