# Default provider: main application + data region.
provider "aws" {
  region = var.aws_region # eu-west-1

  default_tags {
    tags = {
      Project = "uk-clearing-advisor"
      Cycle   = "2027"
      IaC     = "terraform"
    }
  }
}

# CloudFront WAF WebACLs are global-scoped and can only be created in us-east-1.
# AWS platform requirement, not a choice.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project = "uk-clearing-advisor"
      Cycle   = "2027"
      IaC     = "terraform"
    }
  }
}

# Canary end-to-end tester lives in eu-west-2 (London) - a GB-ish vantage plus
# its EIP is explicitly allowlisted in the WAF so it can bypass the GB
# geo-restriction and detect real 403/429/5xx rather than geo-blocks.
provider "aws" {
  alias  = "eu_west_2"
  region = var.canary_region # eu-west-2

  default_tags {
    tags = {
      Project = "uk-clearing-advisor"
      Cycle   = "2027"
      IaC     = "terraform"
    }
  }
}
