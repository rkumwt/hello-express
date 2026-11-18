# hello-express

A small TypeScript + Express API used as a **learning project** to practise a
production-style workflow end to end: code quality tooling, automated tests,
Docker, CI on pull requests, and continuous deployment to AWS EC2.

## Endpoints

| Method | Path      | Response                                  |
| ------ | --------- | ----------------------------------------- |
| GET    | `/`       | `Hello againfrom TypeScript on EC2!`      |
| GET    | `/health` | `{"status":"ok"}` (used by health checks) |

## Tech stack

- **Node.js 22**, **TypeScript 5.9**, **Express 4**
- Native **ES modules** (`"type": "module"`), with `.ts` extensions in imports
- **Vitest** + **supertest** for HTTP tests
- **ESLint** (flat config, typescript-eslint) + **Prettier**
- **Docker** multi-stage build
- **GitHub Actions** for CI/CD, **Amazon ECR** + **EC2** (via SSM) for hosting

## Getting started

```bash
npm install
npm run dev          # http://localhost:3000, reloads on change
```

### Scripts

| Script                 | What it does                                  |
| ---------------------- | --------------------------------------------- |
| `npm run dev`          | Run `src/index.ts` with tsx in watch mode     |
| `npm run build`        | Compile `src/` to `dist/` (tests excluded)    |
| `npm start`            | Run the compiled app (`node dist/index.js`)   |
| `npm test`             | Run the Vitest test suite once                |
| `npm run lint`         | ESLint                                        |
| `npm run typecheck`    | `tsc --noEmit` over `src/` **and** `test/`    |
| `npm run format`       | Format everything with Prettier               |
| `npm run format:check` | Fail if anything isn't formatted (used in CI) |

### Docker

```bash
docker build -t hello-express .
docker run --rm -p 3000:3000 hello-express
```

## Project structure

```
src/
  app.ts            # Express app (routes) — exported, no listen(); imported by tests
  index.ts          # Entry point: imports app and calls listen()
test/
  app.test.ts       # supertest requests against the app, no real port needed
scripts/
  ec2-deploy.sh     # Runs on the EC2 instance: pull, swap container, health check, rollback
docs/
  aws-setup.md      # One-time AWS + GitHub setup for deployment
.github/workflows/
  ci.yml            # Quality gate on every pull request
  deploy.yml        # Build → push to ECR → deploy to EC2 on every merge to main
tsconfig.json       # Type-checking config (src + test), ESM / nodenext
tsconfig.build.json # Build config (src only) used by `npm run build` and Docker
```

### Why `app.ts` and `index.ts` are separate

Tests import `app` and send requests with supertest, without opening a port.
Only `index.ts` calls `listen()`, so importing the app has no side effects.

### ESM and `.ts` imports

Relative imports include the extension: `import app from './app.ts'`.
`rewriteRelativeImportExtensions` makes `tsc` emit `./app.js` in `dist/`, which Node's ESM
loader requires. `tsx` and Vitest understand `.ts` imports directly.

## CI/CD

The workflow follows **trunk-based development**: `main` is protected and always deployable,
and every change goes in through a short-lived branch and a pull request.

```
feature branch ──► Pull request ──► ci.yml
                                     format:check → lint → typecheck → test → build
                                     (required status check; merge blocked if red)
                                        │ merge
                                        ▼
push to main ──► deploy.yml
                  1. ci         (same checks, reused via workflow_call)
                  2. build      docker build once → push to ECR, tagged with git SHA
                  3. deploy     environment "production" (optional approval gate)
                                AWS SSM Run Command → scripts/ec2-deploy.sh on EC2
                                pull → replace container → /health check → auto-rollback
                  4. smoke test curl $APP_URL/health from the internet
```

Principles used:

- **Build once, deploy that same artifact.** The image is tagged with the commit SHA and never rebuilt.
- **Immutable tags.** ECR tag immutability is on, so a SHA always refers to the same image.
- **No long-lived cloud keys.** GitHub authenticates to AWS with **OIDC** and assumes a scoped IAM role.
- **No SSH.** Deployment goes through **SSM Run Command**, so port 22 stays closed.
- **Serialized deploys.** A `concurrency` group prevents two deployments overlapping.
- **Health-checked with automatic rollback** on the instance.

### Rolling back

Actions → **Deploy** → **Run workflow** → enter an earlier commit SHA as `image_tag`.
CI and the build are skipped, and that existing image is redeployed.

### First-time setup

See **[docs/aws-setup.md](docs/aws-setup.md)** for the AWS resources (ECR, EC2, OIDC, IAM)
and the GitHub environment and variables the workflow needs.

## Known limitations / next steps

These are deliberate trade-offs for a learning project:

- **Short downtime during deploy.** With a single instance the container is stopped before the
  new one starts. Next step: an ALB with blue/green, or ECS rolling deployments.
- **Single environment.** Add a `staging` environment and promote the same image tag to production.
- **HTTP only.** Put an ALB with an ACM certificate (or CloudFront) in front for HTTPS.
- **Infrastructure is created by hand.** Next step: define it with Terraform or AWS CDK.
