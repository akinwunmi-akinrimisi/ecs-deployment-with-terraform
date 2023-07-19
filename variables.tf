variable "access_key" {
  description = "AWS access key" 
  
}

variable "secret_key" {
  description = "AWS Secret access key"
   
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