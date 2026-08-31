output "ops_public_ip" {
  description = "ops 노드 공인 IP. 여기로 SSH 접속한다."
  value       = module.ops.public_ip
}

output "redis_private_ips" {
  description = "Redis 노드 사설 IP. Ansible 인벤토리에 넣는다."
  value       = { for k, m in module.redis : k => m.private_ip }
}

output "ssh_command" {
  description = "그대로 붙여 쓰는 접속 명령."
  value       = "ssh -i ~/.ssh/rkm azureuser@${module.ops.public_ip}"
}
