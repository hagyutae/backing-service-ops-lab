variable "subscription_id" {
  description = "구독 ID. az account show --query id -o tsv 로 확인한다."
  type        = string
}

# 구독을 20명이 공유한다. 이름이 겹치면 남의 그룹에 자원을 얹게 되고,
# 전원이 소유자 권한이라 destroy 가 남의 것까지 지운다. 형식을 강제한다.
#
# 세션마다 끝이 다르다. 세션 1 은 -rg, 세션 2 는 -mongo-rg,
# 세션 3 은 -kafka-rg, 세션 4 는 -ops-rg 다.
variable "resource_group_name" {
  description = "rkm-<계정 이름>-ops-rg. 전달받은 계정이 student07 이면 rkm-student07-ops-rg."
  type        = string

  validation {
    condition     = can(regex("^rkm-[a-z0-9]+-ops-rg$", var.resource_group_name))
    error_message = "rkm-<계정 이름>-ops-rg 형식이어야 한다. 다른 수강생의 그룹을 건드리지 않게 막는다."
  }
}

# 이 스택은 세 서비스를 한 번에 올린다. ops-1 과 redis-1·2·3 ·
# mongo-1·2·3 · kafka-1·2·3 으로 열 대다.
#
variable "lab_repo_url" {
  description = "실습 저장소. ops 노드가 부팅할 때 clone 한다. public 이어야 한다."
  type        = string
  default     = "https://github.com/hagyutae/backing-service-ops-lab.git"
}

variable "location" {
  type    = string
  default = "koreacentral"
}

variable "allowed_cidrs" {
  description = "SSH·Grafana·Prometheus 접속을 허용할 출발지. 수강생 PC 의 공인 IP."
  type        = list(string)
}

variable "ssh_public_key_path" {
  description = "SSH 공개 키 파일 경로. Azure 는 RSA 2048비트 이상과 ED25519 를 받는다. 이 과정은 RSA 4096 으로 통일한다."
  type        = string
  default     = "~/.ssh/rkm.pub"
}

variable "tags" {
  type = map(string)
  default = {
    project = "kt-rkm"
    session = "04-operation"
  }
}
