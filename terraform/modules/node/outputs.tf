output "private_ip" {
  value = azurerm_network_interface.this.private_ip_address
}

output "public_ip" {
  value = var.public_ip ? azurerm_public_ip.this[0].ip_address : null
}

output "name" {
  value = azurerm_linux_virtual_machine.this.name
}
