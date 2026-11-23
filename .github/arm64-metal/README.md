# arm64 tests on AWS Graviton bare metal

RunCVM needs `/dev/kvm` to run Container/VMs at full speed. GitHub's arm64 runners have none;
AWS's bare-metal arm64 (Graviton) instances, the `.metal` types, do. The workflow
`.github/workflows/arm64-metal.yml` therefore runs RunCVM's arm64 tests on a `.metal` host that
it launches for the run and terminates afterwards:

1. A GitHub-hosted runner assumes an AWS IAM role by OpenID Connect (no AWS credential is stored
   in GitHub).
2. `launch launch` reaps any host of its group left past its expiry (the workflow sets `REAP=1`),
   then launches a spot host for the instance types in `TYPES`, choosing where by AWS's spot
   placement score (how likely a pool is to have capacity and run without interruption) and then
   by price: the availability zones AWS scores highest come first, cheapest within a score, and
   the rest follow cheapest-first, across every region enabled in the account. It repeats the
   whole ordered pass `SPOT_PASSES` times, since capacity frees up over minutes, and falls back
   to on-demand only when every spot attempt fails. The host builds and installs RunCVM at the
   commit under test.
3. `launch wait` waits for the host's setup to finish, and prints its log.
4. `run-shards` runs the tests on the host over SSH, in 8 shards at once. `summarise` turns the
   shards' results into annotations and a job summary.
5. `launch teardown` terminates the host, and revokes its SSH rule.

`launch`'s header describes its settings.

## When it runs

Nightly (every tier, on `main`); on pull requests labelled `ci:arm64` (the core tier, or the
tier that `ci:extended` or `ci:all` selects); and by hand from the Actions tab, on `main`. Pull
requests from forks are skipped: GitHub gives them no OIDC token.

## A host does not stay up for long after its run

- Before anything else, the host schedules its own poweroff `MAX_MINUTES` after it boots. It is
  launched with shutdown behaviour `terminate`, so the poweroff terminates it, and its root volume
  is deleted on termination. This holds whatever happens to the runner.
- `launch` terminates an instance it started but has not yet reported, on any exit.
- The workflow's teardown step runs at the end of the job, whether the job passed, failed or was
  cancelled.
- The reap `launch launch` runs first when `REAP=1` (as the workflow sets it) terminates any host
  of its group (tag `Group`) whose `Expires` tag has passed by ten minutes. Groups keep CI's hosts (`ci`) apart from those launched
  by hand (`manual`, the default), so that neither reaps the other's.

SSH reaches a host only from the addresses `SSH_CIDR` allows (the launching host's own address by
default): each run adds a rule for them to its group's security group (`runcvm-ci-<group>`), which
teardown revokes, as does reap once the
rule's recorded expiry has passed. Each run's key pair is generated for the run, and its public key
is given to the host in its user data, so no EC2 key pair is involved.

## AWS setup

Every instance, volume and security group `launch` creates is tagged `Project=runcvm-ci`. The
IAM policy below lets it create instances, volumes and security groups only with that tag, add
tags only as it creates them, and terminate, delete or change only resources carrying it, so it
cannot terminate, delete or modify anything else in the account. It lets it launch only the instance types in
`TYPES` (`c6g.metal` and `c7g.metal`), so that leaked credentials could not launch costlier
ones; to consider another type, add it to both. The type condition has a statement of its own,
apart from the volume's: a volume has no instance type, so the condition would refuse it. Its
`Describe*` and pricing reads cannot be scoped: EC2 does not support resource-level permissions
for them.

The same customer-managed policy serves both a maintainer's IAM user (for running `launch` by
hand) and the role that GitHub Actions assumes: a managed policy can be attached to users, groups
and roles alike. In what follows, replace `ACCOUNT_ID` with the AWS account's id.

### The policy (`runcvm-ci`)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnlyDiscovery",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeRegions", "ec2:DescribeInstances", "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceStatus", "ec2:DescribeInstanceTypes", "ec2:DescribeAvailabilityZones",
        "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
        "ec2:DescribeKeyPairs", "ec2:DescribeImages", "ec2:DescribeSpotPriceHistory",
        "ec2:GetSpotPlacementScores", "ssm:GetParameter"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ReadQuotasAndPricing",
      "Effect": "Allow",
      "Action": [
        "servicequotas:GetServiceQuota", "servicequotas:GetAWSDefaultServiceQuota",
        "servicequotas:ListServiceQuotas", "servicequotas:ListAWSDefaultServiceQuotas",
        "servicequotas:ListServices",
        "pricing:GetProducts", "pricing:DescribeServices", "pricing:GetAttributeValues"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RunInstancesCreateTaggedInstance",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:ACCOUNT_ID:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/Project": "runcvm-ci",
          "ec2:InstanceType": ["c6g.metal", "c7g.metal"]
        }
      }
    },
    {
      "Sid": "RunInstancesCreateTaggedVolume",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:ACCOUNT_ID:volume/*",
      "Condition": { "StringEquals": { "aws:RequestTag/Project": "runcvm-ci" } }
    },
    {
      "Sid": "RunInstancesReference",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": [
        "arn:aws:ec2:*:ACCOUNT_ID:network-interface/*",
        "arn:aws:ec2:*:ACCOUNT_ID:security-group/*",
        "arn:aws:ec2:*:ACCOUNT_ID:subnet/*",
        "arn:aws:ec2:*:ACCOUNT_ID:key-pair/*",
        "arn:aws:ec2:*::image/*",
        "arn:aws:ec2:*::snapshot/*"
      ]
    },
    {
      "Sid": "CreateTaggedSecurityGroup",
      "Effect": "Allow",
      "Action": "ec2:CreateSecurityGroup",
      "Resource": "arn:aws:ec2:*:ACCOUNT_ID:security-group/*",
      "Condition": { "StringEquals": { "aws:RequestTag/Project": "runcvm-ci" } }
    },
    {
      "Sid": "CreateSecurityGroupVpcRef",
      "Effect": "Allow",
      "Action": "ec2:CreateSecurityGroup",
      "Resource": "arn:aws:ec2:*:ACCOUNT_ID:vpc/*"
    },
    {
      "Sid": "ImportTaggedKeyPair",
      "Effect": "Allow",
      "Action": "ec2:ImportKeyPair",
      "Resource": "arn:aws:ec2:*:ACCOUNT_ID:key-pair/*",
      "Condition": { "StringEquals": { "aws:RequestTag/Project": "runcvm-ci" } }
    },
    {
      "Sid": "TagOnCreateOnly",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "arn:aws:ec2:*:ACCOUNT_ID:*/*",
      "Condition": {
        "StringEquals": { "ec2:CreateAction": ["RunInstances", "CreateSecurityGroup", "ImportKeyPair"] }
      }
    },
    {
      "Sid": "MutateOwnTaggedResources",
      "Effect": "Allow",
      "Action": [
        "ec2:TerminateInstances", "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress", "ec2:DeleteSecurityGroup", "ec2:DeleteKeyPair"
      ],
      "Resource": "*",
      "Condition": { "StringEquals": { "ec2:ResourceTag/Project": "runcvm-ci" } }
    },
    {
      "Sid": "CreateDefaultNetworking",
      "Effect": "Allow",
      "Action": ["ec2:CreateDefaultVpc", "ec2:CreateDefaultSubnet"],
      "Resource": "*"
    }
  ]
}
```

`launch` reads spot prices and placement scores (`DescribeSpotPriceHistory`,
`GetSpotPlacementScores`) and, only when `PRICE_CAP_PCT` is below 100, on-demand prices through
the Pricing API (`pricing:GetProducts`); it uses no EC2 key pairs and no Service Quotas. The
statements for key pairs (`ImportTaggedKeyPair`, `DeleteKeyPair`, and the key pairs in
`ReadOnlyDiscovery` and `RunInstancesReference`), the Service Quotas actions, and the
instance-discovery reads in `ReadOnlyDiscovery` that `launch` does not call
(`DescribeInstanceTypeOfferings`, `DescribeInstanceStatus`, `DescribeInstanceTypes`,
`DescribeImages`), serve a maintainer's own tools and checks, and may be left out where none are
used.
`CreateDefaultNetworking` cannot be tag-scoped, as the VPC does not exist yet; it creates only a region's free default
VPC and its subnets, untagged.

### The role GitHub Actions assumes

Once per account, register GitHub's OIDC provider:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com
```

Create the role with this trust policy, saved as `trust.json`, which admits this repository's `main`
branch (nightly and manual runs) and its pull requests, and nothing else. GitHub gives no OIDC
token to a pull request from a fork, so `pull_request` admits only pull requests from this
repository's own branches, which only its writers can push:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": [
            "repo:newsnowlabs/runcvm:ref:refs/heads/main",
            "repo:newsnowlabs/runcvm:pull_request"
          ]
        }
      }
    }
  ]
}
```

The workflow asks for a three-hour session, so the role's maximum session duration must allow it:

```bash
aws iam create-role --role-name runcvm-ci-gha --max-session-duration 10800 \
  --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name runcvm-ci-gha \
  --policy-arn arn:aws:iam::ACCOUNT_ID:policy/runcvm-ci
```

Then give the workflow the role's ARN as a repository secret, and create the label. The ARN
grants nothing by itself, but it holds the account id, which the public workflow log would
show if the ARN were a variable; a secret is masked there. `gh secret set` asks for the value,
keeping it out of the shell's history:

```bash
gh secret set AWS_ARM64_METAL_ROLE --repo newsnowlabs/runcvm   # arn:aws:iam::ACCOUNT_ID:role/runcvm-ci-gha
gh label create ci:arm64 --repo newsnowlabs/runcvm --description "Run the arm64 tests on an AWS Graviton bare-metal host"
```

## Running by hand

With AWS credentials for the policy above (e.g. a maintainer's IAM user):

```bash
ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/runcvm-arm64-metal
export RUN=manual-$(date -u +%Y%m%d-%H%M%S) KEY=~/.ssh/runcvm-arm64-metal
PUBKEY=$(cat $KEY.pub) .github/arm64-metal/launch launch   # prints the host's address
IP=<address> .github/arm64-metal/launch wait
ssh -i $KEY ubuntu@<address> bash -s -- 8 /home/ubuntu/results --tier core <.github/arm64-metal/run-shards
scp -r -i $KEY ubuntu@<address>:results .   # each shard's results, in results/shard-<n>
.github/arm64-metal/launch teardown
```

SSH reaches the host only from the address `launch` saw as its own; where the launching host's
outbound address varies (e.g. several gateways in turn), give the range in `SSH_CIDR`, e.g.
`SSH_CIDR=192.0.2.0/24`. Hosts launched by hand are in group `manual` unless `GROUP` says
otherwise, and terminate
themselves after `MAX_MINUTES` (120 by default) if not torn down first. `launch scan` shows the
ordered candidates (score, price, region, AZ, type) without launching anything.
