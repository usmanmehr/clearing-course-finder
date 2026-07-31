# Remote state. Configure in your OWN account before `terraform init`.
# Left commented so this scaffold cannot accidentally contact any backend.
#
# Bootstrap the bucket + lock table once (outside this config), then uncomment:
#
# terraform {
#   backend "s3" {
#     bucket         = "uk-clearing-advisor-tfstate-<account-id>"
#     key            = "2027/terraform.tfstate"
#     region         = "eu-west-2"
#     dynamodb_table = "uk-clearing-advisor-tflock"
#     encrypt        = true
#   }
# }
