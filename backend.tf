terraform {
  backend "s3" {
    bucket         = "terraform-state-geekyrbhalala"
    key            = "unauthorized-s3-access-monitoring/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }
}