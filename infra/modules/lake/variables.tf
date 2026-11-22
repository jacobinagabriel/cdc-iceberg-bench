variable "name" {
  description = "Name prefix for the lake's resources"
  type        = string
}

variable "athena_bytes_scanned_cutoff" {
  description = "Athena stops any query of the workgroup that scans more than this many bytes"
  type        = number
  default     = 10737418240 # 10 GiB
}
