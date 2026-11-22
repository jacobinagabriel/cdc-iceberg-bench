variable "contract_prefix" {
  description = "Where source-app publishes its contract, e.g. /source-app/prod"
  type        = string
}

variable "contract_version" {
  description = "The contract version this repo is written for"
  type        = string
  default     = "4"
}

variable "base_ssm_prefix" {
  description = "Where main-terraform publishes the shared layer, e.g. /main-terraform/prod"
  type        = string
}
