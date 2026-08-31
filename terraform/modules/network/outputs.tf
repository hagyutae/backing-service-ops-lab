output "subnet_id" {
  value = azurerm_subnet.this.id
}

output "subnet_prefix" {
  value = var.subnet_prefix
}
