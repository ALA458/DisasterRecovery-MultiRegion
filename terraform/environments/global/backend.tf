terraform {
  backend "s3" {
    bucket       = "dr-tfstate-559050245919"
    key          = "global/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
