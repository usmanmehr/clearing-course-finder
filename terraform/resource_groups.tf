# Tag-based Resource Groups so the whole 2027 stack is browsable in one place
# per region. Resource Groups are region-scoped, so we create one per region
# the stack deploys into (eu-west-1 app/data, eu-west-2 canary). The query
# matches the normalised tags applied via provider default_tags.
#
# (us-east-1 holds only the CloudFront WAF WebACL + ACM cert; add a third group
# there later if you want those grouped too.)

locals {
  clearing_group_query = jsonencode({
    ResourceTypeFilters = ["AWS::AllSupported"]
    TagFilters = [
      { Key = "Project", Values = ["uk-clearing-advisor"] },
      { Key = "Cycle", Values = ["2027"] },
    ]
  })
}

resource "aws_resourcegroups_group" "clearing_eu_west_1" {
  name        = "uk-clearing-advisor-2027-eu-west-1"
  description = "UK Clearing Advisor 2027 stack resources in eu-west-1 (tag query Project + Cycle)."

  resource_query {
    query = local.clearing_group_query
  }
}

resource "aws_resourcegroups_group" "clearing_eu_west_2" {
  provider    = aws.eu_west_2
  name        = "uk-clearing-advisor-2027-eu-west-2"
  description = "UK Clearing Advisor 2027 stack resources in eu-west-2 (tag query Project + Cycle)."

  resource_query {
    query = local.clearing_group_query
  }
}
