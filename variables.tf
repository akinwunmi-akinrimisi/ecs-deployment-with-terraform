variable "access_key" {
  description = "AWS access key"
  default = "AKIAUUPP6XSTYPVY7246"
  
  
}

variable "secret_key" {
  description = "AWS Secret access key"
  default = "70dV3vNBO1/a6yLc7vqpoKOQPm069zGKg8Xu4MJn"  
  
}

variable "region" {
  description = "Region to deploy infrastructure"
  default     = "eu-west-2"
}

variable "tags" {
  description = "The tags to be added to the resources"
  default = {
    Owner   = "Akinwunmi",
    Project = "Cloudboosta EKS ECS"
  }
}

variable "name" {
  description = "The project name to be used in naming the resources"
  default     = "web-app"
}