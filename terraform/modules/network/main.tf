# 네트워크. 전 세션이 같은 모듈을 쓴다.
#

resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  address_space       = [var.address_space]
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# 공인 IP 가 없는 서비스 노드도 패키지 저장소에는 나가야 한다.
# 2025-09 이후 만들어지는 서브넷은 기본 아웃바운드가 꺼진 채로 생성되므로 명시한다.
resource "azurerm_subnet" "this" {
  name                            = "${var.prefix}-subnet"
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_prefix]
  default_outbound_access_enabled = true
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.prefix}-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# 서브넷 안쪽은 서로 막지 않는다. Redis 6379, Sentinel 26379, exporter 가
# 모두 여기로 오간다. 노드마다 규칙을 쓰면 확장할 때 따라 늘어난다.
resource "azurerm_network_security_rule" "intra" {
  name                        = "allow-intra-subnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.subnet_prefix
  destination_address_prefix  = var.subnet_prefix
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

# SSH 는 수강생 PC 에서만 들어온다. 0.0.0.0/0 을 쓰지 않는다.
resource "azurerm_network_security_rule" "ssh" {
  name                        = "allow-ssh"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.allowed_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

# Grafana 와 Prometheus. ops 노드에만 열린다.
resource "azurerm_network_security_rule" "public" {
  for_each = { for p in var.public_ports : tostring(p) => p }

  name                        = "allow-${each.key}"
  priority                    = 300 + index(var.public_ports, each.value)
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = each.key
  source_address_prefixes     = var.allowed_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

resource "azurerm_subnet_network_security_group_association" "this" {
  subnet_id                 = azurerm_subnet.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}
