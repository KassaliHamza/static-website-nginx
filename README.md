# Static Website on Nginx — Terraform + Ansible on AWS

A static website deployed entirely as code. **Terraform** provisions the AWS
infrastructure and DNS, **Ansible** configures the server and issues a
**Let's Encrypt** certificate, and **GitHub Actions** runs both on every push
using short-lived OIDC credentials — no AWS access keys anywhere.

The result is a site live at `https://<your-domain>` with an automatic
HTTP → HTTPS redirect and auto-renewing certificates.

---

## Architecture

| Layer | Tool | What it creates |
|-------|------|-----------------|
| Compute & network | Terraform | EC2 (Ubuntu 22.04), security group, Elastic IP, SSH key pair |
| DNS | Terraform | Route 53 hosted zone + apex and `www` A records → Elastic IP |
| State | Terraform | S3 backend, versioned and encrypted, with native locking |
| Server config | Ansible | Nginx install, static files, server block |
| TLS | Ansible (certbot) | Let's Encrypt certificate + HTTP → HTTPS redirect |
| CI/CD | GitHub Actions | OIDC role assumption, `terraform apply`, then the playbook |

Terraform owns everything AWS-side; Ansible owns everything that happens *on the
box*. The instance is disposable — its entire configuration lives in this repo.

### How a push becomes a deploy

```
push to main
     │
     ├─ job: terraform ── OIDC → assume role → init (S3 backend) → apply
     │                    └─ outputs: public_ip, security_group_id
     │
     └─ job: deploy ───── OIDC → assume role
                          ├─ authorize port 22 for the runner's own /32
                          ├─ ansible-playbook  (nginx, site files, certbot)
                          └─ revoke port 22          ← runs even on failure
```

Port 22 is **closed by default**. The deploy job opens it to a single address
for the duration of the run and removes the rule afterwards, so there is no
standing SSH exposure.

---

## Repository layout

```
.
├── terraform/
│   ├── providers.tf              # AWS provider, version pins, partial S3 backend
│   ├── variables.tf              # all inputs, with validation
│   ├── main.tf                   # AMI lookup, key pair, security group, instance, EIP
│   ├── dns.tf                    # Route 53 hosted zone + A records
│   ├── outputs.tf                # public_ip, ssh_command, nameservers, security_group_id
│   ├── backend.hcl.example       # copy → backend.hcl (git-ignored)
│   └── terraform.tfvars.example  # copy → terraform.tfvars (git-ignored)
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini.example     # copy → inventory.ini (git-ignored)
│   ├── playbook.yml              # nginx + site + certbot
│   └── site.conf.j2              # templated Nginx server block
├── site/
│   └── index.html                # your static site — replace with anything
└── .github/workflows/deploy.yml   # provision (Terraform) then deploy (Ansible)
```

Nothing account-specific is committed. Every real value lives in a git-ignored
file locally, or in a GitHub Actions variable/secret for CI.

---

## Prerequisites

- An **AWS account**, with the `aws` CLI authenticated (`aws configure`).
- **Terraform** ≥ 1.10 (the S3 backend uses native `use_lockfile` locking).
- The **`gh`** CLI, authenticated (`gh auth login`). `jq` is optional — `gh api --jq`
  uses `gh`'s own engine; only the CloudTrail one-liner in
  [Troubleshooting](#oidc-not-authorized-to-perform-stsassumerolewithwebidentity)
  needs the standalone binary.
- **Ansible** — only needed for manual runs. Use **Linux or WSL**; Ansible has
  no supported Windows control node.
- A **registered domain** from any registrar.

> **WSL users:** keep the repo on the Linux filesystem (`~/projects/...`), not
> under `/mnt/c/...`. Files on `/mnt/c` look world-writable to Linux, which makes
> Ansible silently ignore `ansible.cfg` — and therefore your inventory.

---

## Step-by-step, from a fresh AWS account

### 1. Get the code and create a key pair

```bash
git clone <your-repo-url> static-website-nginx
cd static-website-nginx
```

If you don't already have a key you want to use:

```bash
ssh-keygen -t ed25519 -C "static-site deploy" -f ~/.ssh/id_ed25519
```

The **public** half is uploaded to AWS and authorized on the instance. The
**private** half stays on your machine and is added to GitHub as a secret so CI
can reach the box. It is never committed.

### 2. Bootstrap AWS

Terraform needs somewhere to keep state, and GitHub Actions needs an identity to
assume. Both are one-time setup, done by hand below. Every command is idempotent
except the two `create-` calls, which fail harmlessly if the resource exists.

Set these once — the rest of this section reuses them:

```bash
export AWS_REGION=us-east-2
export PROJECT=static-site
export REPO=<owner>/<repo>
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"
```

#### 2a. State bucket

The bucket name embeds your account ID because S3 names are globally unique.
`us-east-1` is the one region that rejects an explicit `LocationConstraint`:

```bash
if [ "$AWS_REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
fi
```

Then turn on the three things state buckets always want — versioning so a bad
apply is recoverable, encryption at rest, and a hard block on public access:

```bash
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
```

#### 2b. OIDC identity provider

This is what lets GitHub Actions get AWS credentials without a stored access
key. Register it once per account:

```bash
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "ffffffffffffffffffffffffffffffffffffffff"
```

> The thumbprint is a required argument but is no longer load-bearing — AWS
> validates GitHub's certificate against its own trusted CA store. The dummy
> value above is fine.

#### 2c. Find the subject claim GitHub will actually send

**Do not skip this.** GitHub may issue an *immutable* subject that embeds numeric
owner and repo IDs (`repo:owner@23615451/name@1316152201:...`) rather than the
familiar `repo:owner/name:...`. A trust policy written against the wrong shape
rejects every login with `Not authorized to perform sts:AssumeRoleWithWebIdentity`,
and nothing in the error tells you why. Ask GitHub instead of assuming:

```bash
SUB_PREFIX=$(gh api "repos/${REPO}/actions/oidc/customization/sub" \
  --jq '.sub_claim_prefix // empty')
SUB_PREFIX=${SUB_PREFIX:-repo:${REPO}}
echo "$SUB_PREFIX"
```

#### 2d. The role and its trust policy

Trust both the reported prefix and the classic form, so the role keeps working
whichever GitHub sends:

```bash
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": [
          "${SUB_PREFIX}:*",
          "repo:${REPO}:*"
        ]
      }
    }
  }]
}
EOF

aws iam create-role --role-name "github-actions-${PROJECT}" \
  --description "GitHub Actions deploy role for ${REPO}" \
  --assume-role-policy-document file:///tmp/trust-policy.json
```

Re-running later? Use `update-assume-role-policy` instead of `create-role`:

```bash
aws iam update-assume-role-policy --role-name "github-actions-${PROJECT}" \
  --policy-document file:///tmp/trust-policy.json
```

#### 2e. Permissions

Scoped to what this project actually touches — EC2, Route 53, and the one state
bucket — rather than `PowerUserAccess`:

```bash
cat > /tmp/deploy-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketVersioning"],
      "Resource": "arn:aws:s3:::${BUCKET}"
    },
    {
      "Sid": "TerraformStateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    },
    {
      "Sid": "Compute",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "ec2:RunInstances", "ec2:TerminateInstances",
        "ec2:StartInstances", "ec2:StopInstances",
        "ec2:ModifyInstanceAttribute",
        "ec2:CreateTags", "ec2:DeleteTags",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
        "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
        "ec2:ImportKeyPair", "ec2:DeleteKeyPair",
        "ec2:AllocateAddress", "ec2:ReleaseAddress",
        "ec2:AssociateAddress", "ec2:DisassociateAddress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Dns",
      "Effect": "Allow",
      "Action": [
        "route53:CreateHostedZone", "route53:DeleteHostedZone",
        "route53:GetHostedZone", "route53:ListHostedZones",
        "route53:ListHostedZonesByName", "route53:GetChange",
        "route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets",
        "route53:ListTagsForResource", "route53:ChangeTagsForResource"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy --role-name "github-actions-${PROJECT}" \
  --policy-name "${PROJECT}-deploy" \
  --policy-document file:///tmp/deploy-policy.json
```

Finally, print the values you need for the next two steps:

```bash
aws iam get-role --role-name "github-actions-${PROJECT}" --query Role.Arn --output text
echo "bucket = \"${BUCKET}\""
echo "key    = \"${PROJECT}/terraform.tfstate\""
echo "region = \"${AWS_REGION}\""
```

### 3. Configure GitHub

Set the variables the script printed (they are not secrets — they're just
account-specific):

```bash
gh variable set AWS_ROLE_ARN    --body 'arn:aws:iam::<account-id>:role/github-actions-static-site'
gh variable set AWS_REGION      --body 'us-east-2'
gh variable set TF_STATE_BUCKET --body 'static-site-tfstate-<account-id>'
gh variable set TF_STATE_KEY    --body 'static-site/terraform.tfstate'
gh variable set DOMAIN_NAME     --body 'example.com'
gh variable set CERTBOT_EMAIL   --body 'you@example.com'
gh variable set SSH_PUBLIC_KEY  --body "$(cat ~/.ssh/id_ed25519.pub)"
```

Then the single secret:

```bash
gh secret set SSH_PRIVATE_KEY < ~/.ssh/id_ed25519
```

| Name | Kind | Purpose |
|---|---|---|
| `AWS_ROLE_ARN` | variable | Role assumed via OIDC |
| `AWS_REGION` | variable | Region for both provider and state |
| `TF_STATE_BUCKET` / `TF_STATE_KEY` | variable | S3 backend location |
| `DOMAIN_NAME` | variable | Passed to Terraform and certbot |
| `CERTBOT_EMAIL` | variable | Let's Encrypt expiry notices |
| `SSH_PUBLIC_KEY` | variable | Authorized on the instance |
| `AWS_AVAILABILITY_ZONE` | variable *(optional)* | Pin the AZ; blank picks the first |
| `SSH_INGRESS_CIDRS` | variable *(optional)* | JSON list, e.g. `["203.0.113.7/32"]` |
| `SSH_PRIVATE_KEY` | **secret** | How the deploy job reaches the box |

### 4. Configure your local checkout

```bash
cd terraform
cp backend.hcl.example      backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

Edit both with your real values — `backend.hcl` from what step 2 printed,
`terraform.tfvars` with your domain and public key. Both are git-ignored.

```bash
terraform init -backend-config=backend.hcl
```

### 5. Create the infrastructure

Either push to `main` and let CI do it, or run it yourself:

```bash
terraform apply
```

> **`No default VPC for this user`** — some newer AWS accounts ship without one:
> ```bash
> aws ec2 create-default-vpc --region us-east-2
> ```

Collect what you need next:

```bash
terraform output public_ip     # the Elastic IP
terraform output nameservers   # the four Route 53 nameservers
```

### 6. Point your registrar at Route 53

In your registrar's control panel set the domain to **Custom DNS** and enter the
four nameservers from `terraform output nameservers` (drop any trailing dots).

Route 53 is now authoritative, and the A records Terraform created do the work.

### 7. Wait for DNS, then verify

Nameserver changes take minutes to a couple of hours. Query a public resolver so
you're not reading a local cache:

```bash
dig NS example.com +short @8.8.8.8   # the four awsdns servers
dig +short example.com               # your Elastic IP
dig +short www.example.com           # the same IP
```

**Do not skip this.** certbot validates both the apex and `www`, so both must
resolve before a certificate can be issued.

### 8. Deploy

Push to `main` — or run the playbook by hand:

```bash
cd ../ansible
cp inventory.ini.example inventory.ini   # substitute your Elastic IP
ansible-playbook playbook.yml -e "domain=example.com email=you@example.com"
```

This installs Nginx, copies `site/`, writes the server block, installs certbot,
obtains the certificate for both names, and enables the HTTP → HTTPS redirect.
It is idempotent — safe to re-run.

> **On a brand-new domain the first CI deploy will fail at the certbot step** if
> DNS hasn't propagated yet. That's expected. Once `dig` resolves, re-run the
> workflow from the Actions tab (it accepts `workflow_dispatch`) or push again.

### 9. Validate TLS

```bash
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null \
  | openssl x509 -noout -issuer -dates -subject
```

Look for `issuer=... Let's Encrypt`, a valid date window, and your domain in the
subject. `curl -sI http://example.com` should return `301`.

---

## Appendix: a complete run on a fresh account

The steps above are the reference. This appendix records one full run end to end —
a brand-new AWS account, driven from a Windows machine — and documents the places
where reality needed more than the reference text. Follow it as a checklist if your
situation matches. Read it anyway for A4 and A6, whose failure modes are not
platform-specific and cost the most time to diagnose.

Order matters: A1 → A2 before any Terraform, A4 before the trust policy is written,
A6 before the first deploy is attempted.

> **Both shells, every command.** Each block below gives the **bash** form (Linux,
> macOS, WSL, Git Bash) and the equivalent **cmd.exe** one-liner. The differences are
> mechanical and worth internalising once, because they explain most copy-paste
> failures on Windows:
>
> | | bash | cmd.exe |
> |---|---|---|
> | Quoting a JMESPath `--query` | `'...'` | `"..."` — single quotes are literal text |
> | Variables | `$VAR` / `${VAR}` | `%VAR%` |
> | Discard stderr | `2>/dev/null` | `2>nul` |
> | First line of output | `\| head -1` | `\| findstr /R "^HTTP"` |
> | Multi-line documents | heredoc (`<<EOF`) | none — see A3 |
> | Line continuation | `\` | `^` (all blocks below are one-liners anyway) |
>
> These are **cmd.exe** lines, not PowerShell. In Windows PowerShell `curl` is an
> alias for `Invoke-WebRequest` and takes entirely different arguments — use
> `curl.exe` explicitly there, or just open `cmd`.

### A1. Preflight — find out what already exists

Every bootstrap command is either idempotent or fails harmlessly, but knowing the
starting state turns confusing errors into expected ones. First the variables the rest
of the bootstrap reuses:

```bash
export AWS_REGION=us-east-2
export PROJECT=static-site
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"
```

```bat
set AWS_REGION=us-east-2
set PROJECT=static-site
for /f %i in ('aws sts get-caller-identity --query Account --output text') do set ACCOUNT_ID=%i
set BUCKET=%PROJECT%-tfstate-%ACCOUNT_ID%
```

> The `for /f` line captures command output into a variable — cmd.exe has no `$(...)`.
> At the prompt it is `%i`; inside a `.bat` file it must be doubled to `%%i`.

Then the checks:

```bash
aws sts get-caller-identity
aws ec2 describe-vpcs --region "$AWS_REGION" --filters Name=isDefault,Values=true --query 'Vpcs[].VpcId' --output text
aws iam list-open-id-connect-providers
aws iam get-role --role-name "github-actions-${PROJECT}"
aws s3api head-bucket --bucket "$BUCKET"
```

```bat
aws sts get-caller-identity
aws ec2 describe-vpcs --region %AWS_REGION% --filters Name=isDefault,Values=true --query "Vpcs[].VpcId" --output text
aws iam list-open-id-connect-providers
aws iam get-role --role-name github-actions-%PROJECT%
aws s3api head-bucket --bucket %BUCKET%
```

| Command | Reading the result |
|---|---|
| `get-caller-identity` | Your account id. `:root` in the ARN means you are on root credentials |
| `describe-vpcs` | **Empty output = no default VPC** → do A2 |
| `list-open-id-connect-providers` | Empty = OIDC provider not registered yet |
| `get-role` | `NoSuchEntity` = role not created yet |
| `head-bucket` | `404` = state bucket not created yet |

The empty VPC result is the one that matters — see A2.

> **On root credentials.** Bootstrapping as the account root user works and is common
> for a one-time setup, but root cannot be scoped, bounded, or cleanly revoked. Once
> the bootstrap is done, create an IAM admin user and point `aws configure` at that.
> CI never uses root — it assumes the OIDC role.

### A2. Create the default VPC before anything else

AWS accounts created after roughly 2022 ship **without** a default VPC. The security
group and instance both target it, so an apply into a region that has none fails with
`No default VPC for this user`. The reference covers this as a troubleshooting note
under [step 5](#5-create-the-infrastructure); on a genuinely fresh account it is not
an edge case but a required step:

```bash
aws ec2 create-default-vpc --region "$AWS_REGION"
```

```bat
aws ec2 create-default-vpc --region %AWS_REGION%
```

This is per-region — deploying to a second region needs it again.

### A3. Policy documents on Windows

`file:///tmp/trust-policy.json` is a Linux path. The Windows-native `aws.exe` resolves
`file://` against the Windows filesystem, so a heredoc written to `/tmp` from Git Bash
is invisible to it. Write the JSON somewhere real and reference it with forward
slashes:

```bash
aws iam create-role --role-name "github-actions-${PROJECT}" --assume-role-policy-document file:///home/<you>/bootstrap/trust-policy.json
```

```bat
aws iam create-role --role-name github-actions-%PROJECT% --assume-role-policy-document file://C:/Users/<you>/bootstrap/trust-policy.json
```

Note the forward slashes in the Windows path — `aws.exe` accepts them after `file://`
and they avoid a second layer of backslash escaping.

**Writing the document itself has no sane cmd.exe one-liner.** The two policy files in
[2d](#2d-the-role-and-its-trust-policy) and [2e](#2e-permissions) are multi-line JSON
full of double quotes; producing them with chained `echo` and `^"` escaping is
unreadable and easy to get subtly wrong. Use one of these instead:

- **Git Bash or WSL** — the heredocs in step 2 work unchanged. Simplest option.
- **An editor** — paste the JSON, save as UTF-8, pass the path to `--assume-role-policy-document`.
- **PowerShell** — a single-quoted here-string, written explicitly as UTF-8:

```powershell
Set-Content -Path trust-policy.json -Encoding utf8 -Value @'
{ "Version": "2012-10-17", "Statement": [ ... ] }
'@
```

The `-Encoding utf8` is not optional: PowerShell's default encoding produces UTF-16 or
a BOM-prefixed file, and IAM rejects both with a parse error that says nothing about
encoding.

### A4. The immutable subject claim is the common case, not the exception

[Step 2c](#2c-find-the-subject-claim-github-will-actually-send) looks skippable and is
the most expensive step to skip. On this run GitHub returned the **immutable** form:

```
repo:<owner>@<numeric-owner-id>/<repo>@<numeric-repo-id>
```

not `repo:<owner>/<repo>`. A trust policy written against the familiar shape would
have rejected every workflow run with `Not authorized to perform
sts:AssumeRoleWithWebIdentity`, and nothing in that error points at the subject claim.

Ask GitHub what it will send:

```bash
gh api "repos/<owner>/<repo>/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty'
```

```bat
gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq ".sub_claim_prefix // empty"
```

`--jq` is a flag on `gh api`, using the query engine built into `gh` — the standalone
`jq` binary is not involved and does not need to be installed.

Put the reported prefix **first** in the `StringLike` list, keep the classic form as a
fallback, and the role works whichever form GitHub sends. Do not assume your repo
sends the same shape as this one — ask.

### A5. Key type doesn't matter; key hygiene does

The deploy job writes `SSH_PRIVATE_KEY` to `~/.ssh/id_rsa` whatever the algorithm, and
`ansible.cfg` reads that same path — so an ed25519 key works fine despite the
filename, and an existing RSA key needs no conversion. What matters is that the
private half of whatever key you choose now lives in a GitHub secret. Prefer a key
generated for this project alone over a personal key you use elsewhere.

```bash
ssh-keygen -t ed25519 -C "static-site deploy" -f ~/.ssh/static-site-deploy
gh variable set SSH_PUBLIC_KEY --body "$(cat ~/.ssh/static-site-deploy.pub)"
gh secret set SSH_PRIVATE_KEY < ~/.ssh/static-site-deploy
```

```bat
ssh-keygen -t ed25519 -C "static-site deploy" -f %USERPROFILE%\.ssh\static-site-deploy
for /f "delims=" %i in (%USERPROFILE%\.ssh\static-site-deploy.pub) do gh variable set SSH_PUBLIC_KEY --body "%i"
gh secret set SSH_PRIVATE_KEY < %USERPROFILE%\.ssh\static-site-deploy
```

> cmd.exe has no `$(cat ...)`, hence the `for /f` to read the public key file into the
> variable. Both shells accept `<` for redirecting the private key into `gh secret set`,
> which keeps it off the command line and out of your shell history.

### A6. Delegation: verify at the registry, not at a resolver

After changing nameservers at the registrar, the useful question is not "does it
resolve yet" but "what does the registry publish". Public resolvers cache negative
answers and will mislead you in both directions. Ask the TLD's own nameservers, whose
answer is authoritative and uncached:

```bash
dig NS site. +short @8.8.8.8
dig NS example.com +short @ns01.trs-dns.com
```

```bat
nslookup -type=NS site. 8.8.8.8
nslookup -type=NS example.com ns01.trs-dns.com
```

The first command finds the TLD's own nameservers (`.site` here); the second asks one
of them what delegation it publishes for your domain. `nslookup` also exists on Linux
if you'd rather use one syntax everywhere — `dig` is simply the better tool where it
is available.

Once that shows your four `awsdns` servers, public resolvers follow within minutes. In
this run the registry took about seven minutes to pick up the change.

> **A domain that SERVFAILs from every resolver has a broken delegation, not a slow
> one.** The registrar panel here listed four `awsdns` nameservers that looked
> entirely plausible — but they belonged to a hosted zone in a *previous* AWS account,
> long since deleted. AWS assigns a fresh delegation set to every hosted zone, and a
> recreated zone never inherits the old one's servers. Querying the stale servers
> directly returned `Query refused`, which is the giveaway: a live zone answers, a
> dead delegation refuses. Compare all four against the live zone rather than trusting
> a glance — three of the four differed here, and the fourth (`ns-554` vs `ns-559`,
> same suffix) was close enough to read as correct.
> ```bash
> aws route53 get-hosted-zone --id <zone-id> --query 'DelegationSet.NameServers' --output text
> ```
> ```bat
> aws route53 get-hosted-zone --id <zone-id> --query "DelegationSet.NameServers" --output text
> ```
> `terraform output nameservers` gives the same list in either shell.

The step 7 propagation checks translate directly:

| Linux (`dig`) | Windows (`nslookup`) |
|---|---|
| `dig NS example.com +short @8.8.8.8` | `nslookup -type=NS example.com 8.8.8.8` |
| `dig +short example.com` | `nslookup example.com 8.8.8.8` |
| `dig +short www.example.com` | `nslookup www.example.com 8.8.8.8` |

Check more than one resolver — `8.8.8.8`, `1.1.1.1`, `9.9.9.9` — before declaring
propagation done. Both names must return the Elastic IP or certbot cannot validate.

### A7. Deploy without pushing

The reference deploys by pushing to `main`. When the only thing that changed is DNS,
there is nothing to commit — dispatch the workflow directly instead. These are
identical in both shells:

```bash
gh workflow run deploy.yml --ref main
gh run list --limit 3
gh run watch <run-id> --exit-status
```

```bat
gh workflow run deploy.yml --ref main
gh run list --limit 3
gh run watch <run-id> --exit-status
```

`--exit-status` makes the command fail if the run fails, so it works in a script.

### A8. Verify the result, not just the workflow

A green run is not proof the site is correct. Check the redirect, both names, and the
certificate independently:

```bash
curl -sI http://example.com | head -1
curl -sI https://example.com | head -1
curl -sI https://www.example.com | head -1
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | openssl x509 -noout -issuer -dates -subject
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | openssl x509 -noout -ext subjectAltName
```

```bat
curl -sI http://example.com | findstr /R "^HTTP"
curl -sI https://example.com | findstr /R "^HTTP"
curl -sI https://www.example.com | findstr /R "^HTTP"
openssl s_client -connect example.com:443 -servername example.com < nul 2>nul | openssl x509 -noout -issuer -dates -subject
openssl s_client -connect example.com:443 -servername example.com < nul 2>nul | openssl x509 -noout -ext subjectAltName
```

Expect `301` on HTTP and `200` on both HTTPS names.

> cmd.exe has no `head`, so `findstr /R "^HTTP"` picks the status line instead. And
> `echo |` would pipe the literal string `ECHO is on.` into `s_client`, so the cmd form
> uses `< nul` to close stdin cleanly. `openssl` ships with Git for Windows at
> `C:\Program Files\Git\usr\bin\openssl.exe` — add it to `PATH` or run from Git Bash.

The SAN must list **both** `example.com` and `www.example.com`. A certificate covering
only the apex means certbot validated one name and silently skipped the other — the
site works until someone types `www`.

Finally, confirm the deploy job's revoke step actually ran:

```bash
aws ec2 describe-security-groups --group-ids <sg-id> --region "$AWS_REGION" --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,CIDRs:IpRanges[].CidrIp}' --output table
```

```bat
aws ec2 describe-security-groups --group-ids <sg-id> --region %AWS_REGION% --query "SecurityGroups[0].IpPermissions[].{Port:FromPort,CIDRs:IpRanges[].CidrIp}" --output table
```

Only ports 80 and 443 should appear. A lingering port 22 rule means the revoke failed;
the next `terraform apply` clears it.

---

## Everyday use

**Change the site** — edit anything under `site/`, commit, push. The `deploy`
job copies the changed files and reloads Nginx.

**Change infrastructure** — edit `terraform/`, commit, push. Review the plan
locally first with `terraform plan`.

**Certificate renewal** — the certbot package installs a systemd timer that
renews before the 90-day expiry. Nothing to configure.

**SSH in** — port 22 is closed by default. Either add your address to
`ssh_ingress_cidrs` in `terraform.tfvars` and apply, or open it for one session:

```bash
aws ec2 authorize-security-group-ingress --group-id <sg-id> \
  --protocol tcp --port 22 --cidr "$(curl -s https://checkip.amazonaws.com)/32"
```

**Teardown**

```bash
cd terraform && terraform destroy
```

Two things this does *not* undo: the domain registration itself, and the custom
nameservers at your registrar. The state bucket, OIDC provider, and IAM role from
step 2 also survive — delete them by hand if you're done for good.

---

## Security notes

- **No long-lived AWS credentials.** GitHub Actions assumes an IAM role through
  OIDC and receives credentials valid only for the length of the job. There is no
  access key to leak or rotate.
- **The role is scoped**, not `PowerUserAccess`: EC2, Route 53, and the one state
  bucket. The policy is in [step 2e](#2e-permissions).
- **The trust policy is scoped to one repository.** A token from any other repo
  is refused.
- **Port 22 is closed by default** and opened only to the runner's own address
  for the length of a deploy. The revoke step runs under `if: always()`, and if
  it ever fails the next `terraform apply` removes the stray rule, because the
  security group declares its complete desired rule set.
- **Nothing account-specific is committed** — no account IDs, domains, IP
  addresses, or keys. Verify with `git grep` before publishing a fork.
- **The private key in CI also grants you personal SSH access.** For anything
  beyond a personal project use a dedicated deploy key, or move to AWS Systems
  Manager Session Manager and drop port 22 entirely.

---

## Troubleshooting

### OIDC: `Not authorized to perform sts:AssumeRoleWithWebIdentity`

The trust policy's `sub` condition doesn't match the token GitHub actually sent.
GitHub may issue an **immutable subject claim** that embeds numeric IDs:

```
repo:owner@23615451/name@1316152201:ref:refs/heads/main
```

rather than the familiar `repo:owner/name:ref:refs/heads/main`. A `StringLike`
written against the wrong shape can never match. Ask GitHub what it will send:

```bash
gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
```

[Step 2c](#2c-find-the-subject-claim-github-will-actually-send) covers this
during setup, and the trust policy in [step 2d](#2d-the-role-and-its-trust-policy)
accepts both forms. To see the subject that was actually rejected, read
CloudTrail — `userIdentity.userName` on the failed event is the literal claim:

```bash
aws cloudtrail lookup-events --region <region> \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 1 --query 'Events[].CloudTrailEvent' --output text | jq -r .userIdentity.userName
```

Also confirm the workflow grants `permissions: id-token: write`, and remember
that IAM conditions are **case-sensitive** — `Owner/Repo` ≠ `owner/repo`.

### Terraform wants to change `user_data` on every run

You're on Windows and git checked the files out with CRLF. Terraform hashes the
`user_data` heredoc, so a CRLF working tree and an LF one disagree forever: your
machine flips it one way, CI flips it back. `.gitattributes` pins `eol=lf` for
the files Linux reads; if you added files before that, renormalize:

```bash
git add --renormalize .
```

### The playbook takes the site off HTTPS

`certbot --nginx` rewrites `/etc/nginx/sites-available/static-site.conf` in place
to add the 443 block and the redirect. Re-templating that file would strip both,
and the certbot task won't restore them because its `creates:` guard sees the
certificate already on disk. The playbook therefore only writes the server block
**before** a certificate exists.

The tradeoff: once TLS is on, the Nginx config is no longer managed. To change
it, update `site.conf.j2` so it renders the full config *including* the 443
server block and the redirect, then drop the `when:` guard on that task.

### certbot fails with an authorization error

DNS isn't resolving yet, or only the apex resolves. Both `example.com` and
`www.example.com` must return the Elastic IP — recheck with `dig` (step 7).

### Every resolver returns SERVFAIL for the domain

Not propagation — propagation looks like *stale* answers, not failures. SERVFAIL
everywhere means the delegation at the registry points to nameservers that don't serve
the zone. Usually the registrar still lists the nameservers of a hosted zone that was
deleted, often from a previous AWS account; AWS never reissues a delegation set, so a
recreated zone always has different servers. Compare the registrar's four against
`terraform output nameservers` — all four, not just the first.

[A6](#a6-delegation-verify-at-the-registry-not-at-a-resolver) covers the diagnosis,
including how to read the delegation straight from the TLD and skip resolver caching.

### `'domain' is undefined`

You ran the playbook without `-e "domain=... email=..."`. Those are runtime
variables by design, so no domain is committed to the repo.

### SSH host key warnings after rebuilding the instance

Same Elastic IP, new host key:

```bash
ssh-keygen -R <elastic-ip>
```
