# AWS setup for EC2 deployment (one-time)

This is everything that must exist in AWS and GitHub before `deploy.yml` can run.
Commands use the AWS CLI; replace the placeholders first:

```bash
export AWS_REGION=ap-south-1          # your region
export ACCOUNT_ID=123456789012        # aws sts get-caller-identity --query Account --output text
export REPO=hello-express             # ECR repository name
export GH_REPO=rkumwt/hello-express   # GitHub owner/repo
```

## Overview

```
GitHub Actions ──(OIDC, no stored keys)──► IAM role "github-actions-hello-express"
     │                                          │
     ├─ docker push ─────────────────────────► ECR repo "hello-express"
     └─ ssm send-command ────────────────────► EC2 instance (SSM agent)
                                                  │ instance role: SSM + ECR read
                                                  └─ docker pull & run → port 80
```

## 1. ECR repository

Immutable tags mean a tag (git SHA) can never be overwritten, so a deployed tag always
points to the exact same image. Scan-on-push gives free vulnerability scanning.

```bash
aws ecr create-repository --repository-name "$REPO" --region "$AWS_REGION" \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true

# Keep only the last 20 images to control storage cost
aws ecr put-lifecycle-policy --repository-name "$REPO" --region "$AWS_REGION" \
  --lifecycle-policy-text '{"rules":[{"rulePriority":1,"description":"keep last 20",
    "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},
    "action":{"type":"expire"}}]}'
```

## 2. EC2 instance

1. **IAM instance role** (EC2 → trusted entity), name e.g. `hello-express-ec2`, with managed policies:
   - `AmazonSSMManagedInstanceCore` — lets SSM Run Command reach the instance (no SSH needed)
   - `AmazonEC2ContainerRegistryReadOnly` — lets the instance pull from ECR
     If the instance **already has** an instance role, attach these two policies to that
     role instead of creating a new one (an instance can have only one role).
2. **Instance requirements** — use an existing instance or launch a new one:
   - Architecture **x86_64** (e.g. `t3.micro`, `t2.micro`). The workflow builds
     `linux/amd64`; for Graviton `t4g.*` change `platforms` to `linux/arm64`.
   - IAM instance profile: the role above
   - Security group inbound: **HTTP 80 from 0.0.0.0/0**. The deploy uses SSM, so port 22
     is only needed if you log in yourself with EC2 Instance Connect.
   - Nothing else listening on port 80 (e.g. nginx/apache), or change the host port in
     `scripts/ec2-deploy.sh`.
   - **Docker**, the **AWS CLI** and **curl** installed:

     | OS                     | Install                                                                                                                                      |
     | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
     | **Ubuntu** 22.04/24.04 | `sudo apt-get update && sudo apt-get install -y docker.io curl && sudo systemctl enable --now docker && sudo snap install aws-cli --classic` |
     | **Amazon Linux 2023**  | `sudo dnf install -y docker && sudo systemctl enable --now docker` (AWS CLI and curl are preinstalled)                                       |

     Ubuntu and Amazon Linux AMIs already include the **SSM agent**. You can run the
     install command from _Systems Manager → Run Command_ (`AWS-RunShellScript`) or from an
     EC2 Instance Connect session.
3. Verify the instance shows as **Online** in _Systems Manager → Fleet Manager_
   (takes 1–3 minutes after the role is attached; rebooting can speed this up).
   Note its **instance ID** (`i-...`).

## 3. GitHub OIDC provider (once per AWS account)

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

(If it already exists you'll get `EntityAlreadyExists` — that's fine.)

## 4. IAM role for GitHub Actions

**Trust policy** — only this repo's `main` branch and its `production` environment may
assume the role. Jobs that use a GitHub Environment get the subject `environment:production`;
jobs without one get `ref:refs/heads/main`. Allowing both keeps either setup working.

```bash
cat > trust.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": [
          "repo:${GH_REPO}:ref:refs/heads/main",
          "repo:${GH_REPO}:environment:production"
        ]
      }
    }
  }]
}
JSON
aws iam create-role --role-name github-actions-hello-express \
  --assume-role-policy-document file://trust.json
```

**Permissions policy** — least privilege: push to one ECR repo, run commands on EC2 via SSM.

```bash
cat > perms.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EcrAuth", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    {
      "Sid": "EcrPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${REPO}"
    },
    {
      "Sid": "SsmSendCommand",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:instance/*",
        "arn:aws:ssm:${AWS_REGION}::document/AWS-RunShellScript"
      ]
    },
    {
      "Sid": "SsmReadResult",
      "Effect": "Allow",
      "Action": ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"],
      "Resource": "*"
    }
  ]
}
JSON
aws iam put-role-policy --role-name github-actions-hello-express \
  --policy-name deploy --policy-document file://perms.json
```

> Tighten later: replace `instance/*` with your instance ARN, or tag the instance
> (`App=hello-express`) and add a `ssm:resourceTag/App` condition.

## 5. GitHub configuration

**Settings → Environments → New environment → `production`**

- _Deployment branches and tags_: **Selected branches** → `main`
- _Required reviewers_ (optional): add yourself to get a manual approval gate. Both the
  build and deploy jobs use this environment, so each would wait for approval.
- _Environment variables_: add the variables below **here, on the `production` environment**
  (none of them are secret, so no Secrets are needed). The workflow reads them only in jobs
  that declare `environment: production`.

| Variable          | Example                                                             |
| ----------------- | ------------------------------------------------------------------- |
| `AWS_REGION`      | `ap-south-1`                                                        |
| `AWS_ROLE_ARN`    | `arn:aws:iam::123456789012:role/github-actions-hello-express`       |
| `ECR_REPOSITORY`  | `hello-express`                                                     |
| `EC2_INSTANCE_ID` | `i-0abc123def4567890`                                               |
| `APP_URL`         | `http://<instance-public-ip-or-dns>` (optional, enables smoke test) |

## 6. Troubleshooting

| Symptom                                                   | Likely cause                                                                                                  |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` doesn't match (check repo name / `main` / environment name), or OIDC provider missing      |
| `InvalidInstanceId` from `send-command`                   | Instance not registered with SSM: missing instance role, SSM agent not running, or no outbound internet/HTTPS |
| `docker: command not found` in deploy output              | User data didn't run — install Docker manually via Session Manager                                            |
| `no basic auth credentials` on pull                       | Instance role lacks `AmazonEC2ContainerRegistryReadOnly`                                                      |
| `exec format error` in container logs                     | CPU architecture mismatch (amd64 image on arm64 instance or vice versa)                                       |
| Deploy succeeds but browser can't connect                 | Security group missing inbound port 80, or using `https://`                                                   |
