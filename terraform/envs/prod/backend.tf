terraform {
  backend "s3" {
    # Bucket, and the rest, come from backend.hcl at init time:
    #   tofu init -backend-config=backend.hcl
    key          = "gurudev/prod/terraform.tfstate"
    region       = "ca-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
