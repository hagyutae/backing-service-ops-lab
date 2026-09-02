output "ops_public_ip" {
  description = "ops 노드 공인 IP. 여기로 SSH 접속한다."
  value       = module.ops.public_ip
}

output "ssh_command" {
  description = "그대로 붙여 쓰는 접속 명령."
  value       = "ssh -i ~/.ssh/rkm azureuser@${module.ops.public_ip}"
}

# ── cloud-init 이 이미 배치했다 ──────────────────────────────
# ops 노드가 부팅할 때 이 값이 그대로 인벤토리 자리에 들어간다.
# 이 output 은 인벤토리를 손으로 고친 뒤 원본을 다시 볼 때 쓴다.
#
#   terraform output -raw inventory
output "inventory" {
  description = "ops 노드에 배치할 Ansible 인벤토리. 세 서비스 그룹이 모두 들어 있다."
  value       = local.inventory
}

output "service_private_ips" {
  description = "서비스 노드 아홉 대의 사설 IP. 실습 명령의 대상이다."
  value = merge(
    { for k, m in module.redis : k => m.private_ip },
    { for k, m in module.mongo : k => m.private_ip },
    { for k, m in module.kafka : k => m.private_ip },
  )
}
