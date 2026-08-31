terraform {
  # 1.9 부터 variable validation 이 다른 변수를 참조할 수 있다.
  # 단계 스위치가 하나만 켜졌는지 plan 단계에서 막는 데 그 기능을 쓴다.
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  # azurerm 4.x 는 az login 이 돼 있어도 구독 ID 를 명시해야 한다.
  subscription_id = var.subscription_id
}
