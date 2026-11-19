variable "name" {
  description = "Repository name."
  type        = string
}

variable "regions" {
  description = "Regions that get a copy of the repository."
  type        = list(string)
}

variable "keep_images" {
  description = "How many images the lifecycle policy keeps."
  type        = number
  default     = 20
}
