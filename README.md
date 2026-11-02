# UltraDoc AI

- Document intelligence for logistics paperwork.
- Upload a rate confirmation, bill of lading, or similar PDF/DOCX/TXT/image document.
- Ask questions across one document or many, with cited sources and a confidence score.
- Extract structured shipment fields.

**Live:** [ultradoc-ai.vercel.app](https://ultradoc-ai.vercel.app) · API:
`https://ultradoc-api.onrender.com`

## Overview

- **Upload** → parse → chunk → embed → store in a local vector index.
- **Ask** → retrieve the most relevant chunks across every document visible to
  the session, generate a grounded answer, and return it with supporting
  source text and a confidence score.
  - If the question's evidence spans more than one document, the model
    synthesizes **one** answer that names each document's value and explains
    any real discrepancy.
  - It never blocks on "which document did you mean?" and never splits the
    answer into one block per document.
  - Three guardrail layers keep answers honest, including refusing outright
    when no uploaded document contains the information.
- **Extract** → pull 13 structured shipment fields (pickup/delivery location,
  dates, PO number, commodity, weight, rate, etc.) out of one or many
  documents as typed JSON, with `null` for anything not explicitly present.
  - Field selection follows what's actually repetitive across real logistics
    paperwork.
  - Reference ID, pickup/delivery location, pickup/delivery date, PO number,
    commodity, weight, and quantity appear on essentially every bill of
    lading and rate confirmation.
  - Equipment type, rate, currency, and carrier name are common on rate
    confirmations but typically absent from a bill of lading.

- LLM inference runs through a single OpenAI-compatible client: **Groq** by
  default, or any self-hosted **Ollama** server exposing an `/v1` endpoint,
  with no code changes required to switch.
- Embeddings and reranking run **locally** via
  [fastembed](https://github.com/qdrant/fastembed). No cloud embedding key
  needed.
- Scanned PDF pages and image uploads (PNG/JPG/WEBP) are OCR'd locally via
  [pytesseract](https://github.com/madmaze/pytesseract). No cloud vision API
  needed either.

## Quickstart

- Prerequisites: [uv](https://docs.astral.sh/uv/), [pnpm](https://pnpm.io/),
  Python 3.12, Node 22+, and the `tesseract-ocr` binary.
  - macOS: `brew install tesseract`. Debian/Ubuntu: `apt-get install
    tesseract-ocr`. The Docker image installs it automatically.
- Or skip all of that and use [mise](https://mise.jdx.dev/) (see below).

```bash
# Backend
cd apps/api
cp .env.example .env          # fill in LLM_API_KEY (Groq key, or leave blank for Ollama)
uv sync
uv run python scripts/make_sample_docs.py   # generates sample logistics docs
uv run python scripts/prefetch_models.py    # downloads embedding + reranker models (~170MB, one-time)
uv run uvicorn app.main:app --reload --port 8000

# Frontend (new terminal)
cd apps/web
cp .env.example .env.local
pnpm install
pnpm dev
```

Open http://localhost:3000, upload a document, and start asking questions.

### One-command dev with mise

```bash
mise install      # pins python/node/pnpm/uv to the versions in mise.toml
mise run dev       # runs backend + frontend together, interleaved output
```

Or the plain npm-script equivalents from the repo root: `pnpm dev:api` /
`pnpm dev:web` (see [package.json](package.json)).

### Using Ollama instead of Groq

Set in `apps/api/.env`:

```bash
LLM_BASE_URL=http://localhost:11434/v1
LLM_API_KEY=ollama
LLM_MODEL=llama3.1
```

The same code path (`app/llm/client.py`) serves both providers. Groq and
Ollama both speak the OpenAI chat-completions API.

## Architecture

```mermaid
flowchart LR
    subgraph Upload
        A[PDF / DOCX / TXT / Image] --> B["Parse<br/>pymupdf / python-docx<br/>+ pytesseract OCR fallback"]
        B --> C["Chunk<br/>recursive splitter, 1200/200"]
        C --> D["Embed<br/>fastembed all-MiniLM-L6-v2"]
        D --> E[("Chroma<br/>vector store")]
    end

    subgraph Ask["Ask (one or many documents)"]
        F[Question] --> G[Embed query]
        G --> H["ANN search in Chroma<br/>(every doc visible to session)"]
        H --> I["Cross-encoder rerank<br/>ms-marco-MiniLM-L-6-v2"]
        I --> J{Confident<br/>evidence?}
        J -- no --> K["Refuse:<br/>Not found in document"]
        J -- yes --> L["LLM generates ONE<br/>grounded answer<br/>(explains cross-doc conflicts)"]
        L --> M{Model says<br/>not found?}
        M -- yes --> K
        M -- no --> N["Grounding verifier<br/>checks claims vs sources"]
        N -- unsupported --> K
        N -- "supported / partial" --> O["Answer + sources<br/>+ confidence score"]
    end

    E --> H

    subgraph Extract
        P[Full document text] --> Q["LLM structured output<br/>13 shipment fields"]
        Q --> R["Typed JSON,<br/>null where absent"]
    end
```

## Deployment architecture

```mermaid
flowchart TB
    User[Browser] -->|HTTPS| Vercel

    subgraph GH["GitHub: dev-eloper-365/ultradoc-ai"]
        Repo[(master branch)]
    end

    Repo -->|"git push<br/>root dir: apps/web"| Vercel["Vercel<br/>Next.js frontend"]
    Repo -->|"git push<br/>Docker build, context: apps/api"| Render["Render (free tier)<br/>FastAPI backend, Docker"]

    Vercel -->|"HTTPS + CORS<br/>(FRONTEND_URL allowlist)"| Render
    Render -->|"OpenAI-compatible<br/>chat completions"| Groq[Groq API<br/>llama-3.3-70b-versatile]

    subgraph RenderBox[" "]
        Render
        Chroma[("Chroma<br/>(ephemeral,<br/>no disk on free tier)")]
        Models["fastembed models<br/>~170MB<br/>(baked into image)"]
        Render --- Chroma
        Render --- Models
    end
```

A full editable diagram source is at
[`docs/architecture.drawio`](docs/architecture.drawio) (open in
[draw.io](https://app.diagrams.net) or the VS Code draw.io extension).

Notable deployment-specific decisions, in case you're standing this up
yourself:

- **Vercel project root is `apps/web`**, not the repo root. This is a
  monorepo with two independent lockfiles.
  - The Vercel *Root Directory* project setting has to point at `apps/web`
    explicitly.
  - Otherwise Vercel clones the whole repo, finds no `build` script at the
    top level, and silently produces an empty deployment (build "succeeds"
    in ~50ms, then every route 404s).
  - A `.vercelignore` at the repo root excludes `apps/api` entirely: 546MB
    `.venv` plus up to ~1.4GB of local model-cache/vector-store data
    accumulated during dev, none of it relevant to the frontend build.
  - Vercel's local-upload path doesn't fully honor `.gitignore` for a
    monorepo the way `git` itself does.
- **Framework Preset must be set explicitly to `Next.js`.**
  - A freshly created Vercel project defaults to `Other`.
  - The build step still runs fine (the local `vercel build` invocation
    auto-detects Next.js and produces correct output).
  - But the *platform* doesn't register the deployment as a Next.js app for
    routing purposes: every route 404s at the edge layer despite a
    successful build.
  - Easy to miss, since the build logs look completely normal.
- **Deployment Protection (Vercel SSO)** is on by default for a new project.
  - Gates every URL, including production, behind a Vercel login wall.
  - Turn it off for a public-facing app: `vercel project protection disable
    <project> --sso`.
- **CORS is two-sided.**
  - The frontend's `NEXT_PUBLIC_API_BASE_URL` has to point at the Render
    URL.
  - The backend's `FRONTEND_URL` has to point back at the Vercel URL
    (`app_factory.py` builds its CORS allowlist from it).
  - Getting one side right and not the other produces a confusing partial
    failure: `curl` against the API works fine (curl doesn't enforce CORS),
    but the browser blocks every request with "No
    'Access-Control-Allow-Origin' header."
  - Looks like a backend bug until you check both env vars.
- **Render's free tier has no persistent disk.**
  - Uploaded files and the Chroma index live on the container's ephemeral
    filesystem.
  - Wiped on every restart or redeploy: acceptable for a demo, not for real
    use.
  - See [`render.yaml`](render.yaml) for the "bump plan, add a disk block"
    path back to persistence.

## DevOps Setup

A self-hosted deployment of the same app, built for running on a single
Ubuntu Server 24.04/26.04 VM (VMware Workstation or VirtualBox). Everything is free and local: Docker for
runtime, Terraform for infrastructure, LocalStack in place of AWS, and GitHub
Actions with a self-hosted runner for CI/CD. The Vercel/Render setup above is
unchanged.

### Architecture

```mermaid
flowchart LR
    Dev[Developer] -->|pull request| GH[GitHub]
    GH -->|pull_request| CI["CI (GitHub-hosted)<br/>ruff + pytest, biome,<br/>image build + Trivy"]
    GH -.->|"push to main<br/>(runner polls outbound)"| Runner

    Browser -->|HTTPS :443| Nginx

    subgraph VM["Ubuntu 26.04 VM (VMware/VirtualBox) · UFW 22/80/443 · fail2ban"]
        Runner["GitHub self-hosted runner<br/>docker build :sha<br/>terraform apply"]
        Cron["cron<br/>backup.sh daily<br/>healthcheck.sh every 5 min"]

        subgraph Docker["Docker network ultradoc_net (terraform/docker)"]
            Nginx["nginx<br/>TLS, gzip, rate limit"]
            Web["web<br/>Next.js :3000"]
            API["api<br/>FastAPI :8000"]
            Vol[("ultradoc_data<br/>uploads + Chroma")]
            LS["LocalStack :4566<br/>S3 + IAM<br/>(terraform/aws-local)"]
        end
    end

    Nginx -->|/| Web
    Nginx -->|"/api/* (prefix stripped)"| API
    API --> Vol
    API -->|chat completions| Groq[Groq API]
    Runner -->|apply| Docker
    Cron -->|tar.gz| Vol
    Cron -->|upload| LS
```

| Piece | Where | What it does |
|---|---|---|
| Hardened images | `apps/*/Dockerfile`, `.dockerignore` | Non-root users, `HEALTHCHECK`, models baked to `/app/models`, no `.env` in images |
| Readiness probe | `GET /ready` | 200 only if the data dir is writable and Chroma opens (`/health` is liveness) |
| Reverse proxy | `nginx/default.conf` | `/` → web, `/api/*` → api (prefix stripped), HTTP→HTTPS, gzip, 10 r/s rate limit, 10 MB body limit |
| App infrastructure | `terraform/docker/` | kreuzwerker/docker: network, data volume, api/web/nginx/LocalStack containers |
| AWS-style resources | `terraform/aws-local/` | hashicorp/aws → LocalStack: versioned, encrypted backup bucket with lifecycle rules; least-privilege IAM user |
| Server setup | `scripts/server-setup.sh` | Deploy user, key-only SSH, UFW, fail2ban, Docker, Terraform, AWS CLI, swap, unattended upgrades |
| Operations | `scripts/{backup,restore,healthcheck}.sh` | Volume backups to S3, restores, health reports (see [docs/RUNBOOK.md](docs/RUNBOOK.md)) |
| CI/CD | `.github/workflows/{ci,deploy}.yml` | PR checks; deploy to the VM with automatic rollback |

### CI/CD flow

- **Pull request → `ci.yml`** (GitHub-hosted runners):
  1. API: `ruff check` + `pytest` (`/health`, `/ready`).
  2. Web: `biome check`.
  3. Build both images and scan them with Trivy; any fixable CRITICAL CVE fails the PR.
- **Push to `main` → `deploy.yml`** (self-hosted runner on the VM):
  1. Build `ultradoc-api:<git-sha>` and `ultradoc-web:<git-sha>` on the VM (no registry needed).
  2. `terraform apply -var image_tag=<git-sha>` replaces only containers whose image changed.
  3. Health check through nginx (`/api/health` + `/api/ready`, 10 tries × 6 s).
  4. Success: record the tag in `/opt/ultradoc/state/current_tag`, install `scripts/` for cron, prune old images (keeps current + previous).
  5. Failure: `terraform apply` with the previous tag, re-check, and fail the job.
- Secrets live only in GitHub Actions secrets (`LLM_API_KEY`) and reach Terraform as `TF_VAR_llm_api_key`.
- Actions are pinned to commit SHAs.
- The self-hosted runner only runs `deploy.yml` on pushes to `main`, never on PRs, so code from forks never executes on the VM.
- Known limitation: there is one container per service, replaced in place. A failed release
  means about 2–3 minutes of API downtime until the rollback finishes (tested by deploying an
  image whose healthcheck never passes). Blue/green behind nginx would remove that.

### Run the stack locally (Docker Compose)

```bash
scripts/gen-certs.sh
docker compose up --build            # https://localhost (accept the self-signed cert)
# Ports 80/443 busy? HTTP_PORT=8080 HTTPS_PORT=8443 docker compose up --build
```

### Bring it up on a fresh VM

**On your PC:**
1. Create a VM (VMware Workstation or VirtualBox; tested on VMware Workstation 17 + Ubuntu 26.04.1):
   - Ubuntu Server 24.04 or 26.04 LTS ISO, 2–4 vCPU, 6 GB RAM, 40 GB disk (store it on a drive with space).
   - Network: NAT (VMware: the PC reaches the VM IP directly) or Bridged. VirtualBox NAT needs port forwards 2222→22, 443→443.
   - In the installer: untick "LVM group" (else only half the disk is used), tick **Install OpenSSH server**, pick no snaps (not docker).
2. Copy your SSH key to the VM (PowerShell):
   ```powershell
   ssh-keygen -t ed25519            # once, if you have no key yet
   type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <user>@<vm-ip> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
   ```

**On the VM**, as the user you created during install:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<you>/ultradoc-ai.git && cd ultradoc-ai
sudo scripts/server-setup.sh          # creates "deploy", hardens SSH (key-only from now on)
```

Then, as `deploy` (`ssh deploy@<vm-ip>`):

```bash
git clone https://github.com/<you>/ultradoc-ai.git ~/ultradoc-ai && cd ~/ultradoc-ai

# 1. TLS cert covering the VM's IP
CERT_DIR=/opt/ultradoc/certs scripts/gen-certs.sh <vm-ip>

# 2. First build (later builds come from the deploy workflow)
docker build -t ultradoc-api:manual apps/api
docker build -t ultradoc-web:manual --build-arg NEXT_PUBLIC_API_BASE_URL=/api/ apps/web

# 3. App + LocalStack containers
cd terraform/docker
terraform init -backend-config="path=/opt/ultradoc/state/docker.tfstate"
read -rs TF_VAR_llm_api_key && export TF_VAR_llm_api_key      # paste the Groq key
terraform apply -var image_tag=manual -var cert_dir=/opt/ultradoc/certs
echo manual > /opt/ultradoc/state/current_tag

# 4. Backup bucket + IAM user in LocalStack
cd ../aws-local
terraform init -backend-config="path=/opt/ultradoc/state/aws-local.tfstate"
terraform apply

# 5. Config for the ops scripts (holds the backup user's keys)
install -m 600 ~/ultradoc-ai/scripts/ultradoc.env.example /opt/ultradoc/ultradoc.env
sed -i "s|^AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=$(terraform output -raw backup_access_key_id)|; \
        s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$(terraform output -raw backup_secret_access_key)|" \
  /opt/ultradoc/ultradoc.env

# 6. Ops scripts + cron
cp -a ~/ultradoc-ai/scripts /opt/ultradoc/app/
crontab ~/ultradoc-ai/scripts/crontab.example
/opt/ultradoc/app/scripts/healthcheck.sh && /opt/ultradoc/app/scripts/backup.sh
```

Open `https://<vm-ip>` from your PC and accept the self-signed certificate.

Cron entries (`scripts/crontab.example`):

```cron
2   2 * * *  /opt/ultradoc/app/scripts/backup.sh >> /opt/ultradoc/logs/backup.log 2>&1
*/5 * * * *  /opt/ultradoc/app/scripts/healthcheck.sh > /dev/null 2>&1
```

### GitHub setup (secrets + self-hosted runner)

1. **Secret:** repo → Settings → Secrets and variables → Actions → *New repository secret*:
   `LLM_API_KEY` = your Groq key. Optional *variable* `LLM_MODEL` (default `openai/gpt-oss-120b`).
2. **Runner:** repo → Settings → Actions → Runners → *New self-hosted runner* → Linux x64.
   Run the download commands it shows on the VM as `deploy` (in `~/actions-runner`), then:
   ```bash
   ./config.sh --url https://github.com/<you>/ultradoc-ai --token <token-from-page> \
     --name ultradoc-vm --labels ultradoc --unattended
   sudo ./svc.sh install deploy && sudo ./svc.sh start
   ```
   The runner connects outbound to GitHub, so the VM needs no inbound port for it.
3. Push to `main`, then watch the **Deploy** run under the Actions tab.

Day-2 operations (app down, disk full, backup/restore, rollback, certificate
renewal, logs) are in [docs/RUNBOOK.md](docs/RUNBOOK.md).

## API reference

- All endpoints are root-level (no version prefix).
- Send an `X-Session-Id` header (any client-generated string) to scope
  uploaded documents to that session.
- Omit it and every endpoint operates unscoped: every document ever uploaded
  to the instance. This is the "direct API/script caller" path, not what the
  web UI does.

### `POST /upload`

- Multipart form with a `file` field (PDF, DOCX, TXT, PNG, JPG, or WEBP, max
  10MB by default).
- Scanned PDF pages and image files are OCR'd via pytesseract before
  chunking.
- `POST /upload/batch` (`files[]`, multiple) uploads several documents in one
  request, isolating per-file failures.

```json
{
  "document_id": "11a6837c0058558a",
  "filename": "rate_confirmation.pdf",
  "pages": 2,
  "chunk_count": 4,
  "status": "ready"
}
```

- Re-uploading identical bytes returns the same `document_id` (content-hash
  dedupe) instead of re-processing.

### `POST /ask`

```json
{ "question": "What is the agreed rate?", "document_ids": null, "history": null }
```

- `document_ids` is optional.
  - Omitted (or empty): retrieval searches every document visible to the
    session, and the model synthesizes one answer, naming which document
    each fact came from when they disagree.
  - Given: the question is scoped to just those IDs, intersected with what
    the session can actually see (see [Security](#security)).
- `history` is the client's own recent chat turns (`[{"role":
  "user"|"assistant", "content": str}]`).
  - Used only to resolve follow-ups like "what about the delivery date
    instead?"
  - Never used as a source of facts.

```json
{
  "answer": "- Reference ID: LD53657",
  "refused": false,
  "sources": [
    {
      "text": "...Reference ID\nLD53657\nPhone\n+919884954552...",
      "page": 2,
      "chunk_index": 3,
      "score": 0.681,
      "document_id": "11a6837c0058558a",
      "filename": "LD53657-Carrier-RC.pdf"
    }
  ],
  "confidence": 0.841,
  "confidence_tier": "high",
  "confidence_breakdown": { "retrieval": 0.681, "agreement": 1.0, "grounding": 1.0 },
  "model": "llama-3.3-70b-versatile"
}
```
*(a real response, captured from the live Render deployment)*

### `POST /extract`

```json
{ "document_ids": null }
```

- Same scoping rule as `/ask`.
- Omitted: extracts from every document visible to the session.
- One result per document either way.

```json
{
  "results": [
    {
      "document_id": "11a6837c0058558a",
      "filename": "LD53657-Carrier-RC.pdf",
      "data": {
        "reference_id": "LD53657",
        "pickup_location": "AAA, Los Angeles International Airport (LAX), World Way, Los Angeles, CA, USA",
        "delivery_location": "xyz, 7470 Cherry Avenue, Fontana, CA 92336, USA",
        "pickup_date": "2026-02-08",
        "delivery_date": "2026-02-08",
        "po_number": "112233ABC",
        "commodity": "Ceramic",
        "weight": 56000,
        "quantity": "10000 units",
        "equipment_type": "Flatbed",
        "rate": 400,
        "currency": "USD",
        "carrier_name": "SWIFT SHIFT LOGISTICS LLC"
      },
      "error": null
    }
  ]
}
```

- Every field is `null` when not explicitly present in the document.
- The extraction prompt is instructed never to infer or guess a value.
- Includes never fabricating a time-of-day onto a date the document only
  gives as a bare date (a real bug this session caught and fixed, see
  [Failure cases found and fixed](#failure-cases-found-and-fixed)).

### Extras

- `GET /documents`: every document visible to the session, most recently
  uploaded first.
- `GET /documents/{id}/file`: the original uploaded bytes, for inline
  preview.
  - Always requires a session that can see that document.
  - The one endpoint that does *not* fall back to unscoped access when
    `X-Session-Id` is missing (see [Security](#security)).
- `GET /health`: liveness probe.
- `GET /ready`: readiness probe. 200 only when the data dir is writable and
  the Chroma store opens; 503 with the failing check otherwise.

## Chunking strategy

- Each page is split independently with a recursive character splitter
  (paragraph → sentence → word → character boundaries).
- 1200 characters per chunk, 200 characters of overlap
  (`app/rag/chunking.py`, `app/constants/rag.py`).
- Splitting per-page, rather than across page breaks, keeps every chunk's
  `page` metadata exact.
- DOCX tables (rate confirmations are table-heavy) are row-joined
  (`"Cell A | Cell B"`) and appended after the running paragraph text, so
  structured fields inside tables aren't lost.

## Retrieval

1. Embed the query with the same embedding model used for passages (with its
   asymmetric query-instruction prefix).
2. ANN search the Chroma collection: every document visible to the session
   unless `document_ids` scopes it. Cosine space, top 12 candidates.
3. Cross-encoder rerank over those candidates.
4. Blend: `score = 0.6 · rerank_norm + 0.4 · cosine_norm`.
5. Mark each chunk **confident** if its raw cosine *or* raw rerank logit
   clears an absolute bar (not just relative rank). This catches cases where
   the two signals disagree.
6. Cap non-confident ("weak") chunks at 4 so an unanswerable query doesn't
   return a full page of noise, and drop any chunk scoring below 15% of the
   top score (relevance dropoff; see the calibration note below for why this
   isn't 40% anymore).

All thresholds live in `app/constants/rag.py`.

### The embedding/reranker model, and why it changed

```mermaid
flowchart LR
    subgraph Before["❌ First choice: deployed, then OOM'd on Render free tier"]
        direction TB
        E1["mxbai-embed-large-v1<br/>1024-dim embeddings<br/>1.2 GB"]
        R1["jina-reranker-v1-turbo-en<br/>cross-encoder rerank<br/>156 MB"]
        T1["= 1.36 GB of model weights<br/>on a 512MB container"]
        E1 --> T1
        R1 --> T1
    end

    subgraph After["✅ Switched to: fits the free tier"]
        direction TB
        E2["all-MiniLM-L6-v2<br/>384-dim embeddings<br/>90 MB"]
        R2["ms-marco-MiniLM-L-6-v2<br/>cross-encoder rerank<br/>80 MB"]
        T2["= 170 MB of model weights<br/>same two-stage design kept"]
        E2 --> T2
        R2 --> T2
    end

    T1 -.->|"512MB RAM limit hit:<br/>/upload 502'd every time<br/>(health check passed, models never loaded)"| After
```

**First choice:**
- `mxbai-embed-large-v1` (1024-dim embeddings) + `jina-reranker-v1-turbo-en`
  (cross-encoder), both run locally via fastembed.
- Chosen for retrieval quality, on the assumption that this would run on a
  normal machine with normal RAM.
- Worked well in local dev the entire time this project was built.

**What broke:**
- Deploying the backend to Render's free tier (512MB RAM) for a public demo.
- `GET /health` kept passing, since it never touches the ML models, which
  made the service *look* fine.
- Every real request (`/upload`, `/ask`, `/extract`) 502'd: the container
  OOM-crashed the moment it tried to load the models.
- `du -sh` on the local model cache made the reason obvious:

```
1.2G  models--mixedbread-ai--mxbai-embed-large-v1
156M  models--jinaai--jina-reranker-v1-turbo-en
```

- 1.36GB of model weights alone, before FastAPI/Chroma/Python's own
  baseline, on a 512MB container.
- Not a logic bug: a capacity mismatch.

**The switch:**
- Queried fastembed's own model catalog
  (`TextEmbedding.list_supported_models()` /
  `TextCrossEncoder.list_supported_models()`) for the smallest options.
- Kept the *same two-stage architecture* (dense retrieval + cross-encoder
  rerank) rather than dropping the reranker outright.
- Reranking had already proven, in eval testing, to catch cases where raw
  cosine similarity ranked the wrong chunk first.

```
sentence-transformers/all-MiniLM-L6-v2   : 0.09 GB  (embedding)
Xenova/ms-marco-MiniLM-L-6-v2            : 0.08 GB  (reranker)
```

- ~170MB combined vs. 1.36GB before: comfortably under 512MB, with room for
  request-time overhead.

**The part that isn't free:**
- The smaller models produce a *materially different, more compressed* raw
  score distribution than the originals.
- Not just "somewhat lower everywhere": a different shape.
- Measured directly: a real query, retrieval and reranking called in
  isolation, bypassing the LLM entirely, on the exact same document and
  question.

| | old models | new models |
|---|---|---|
| top cosine similarity | ~0.4-0.9 typical | **0.24** (this query's ceiling) |
| reranker logit, relevant chunk | needed to clear **-2.5** | clustered at **-5.8 to -6.0** |
| reranker logit, irrelevant chunk | n/a | **-11 to -11.5** |

- The old `CONFIDENT_COSINE` (0.55) and `CONFIDENT_RERANK_LOGIT` (-2.5)
  thresholds were calibrated for the old models' range.
- *Unreachable* by the new models on this query: every chunk silently scored
  "not confident."
- Capped the `agreement` component of every answer's confidence at 0, even
  when the answer itself was correct.
- Confidence dropped from `high` to `medium` across the board, despite
  content quality holding.
- Recalibrated to `CONFIDENT_COSINE = 0.20` and `CONFIDENT_RERANK_LOGIT =
  -7.0`, set just past the real relevant/irrelevant cluster boundary
  measured above, not guessed.
- Re-verified against the same eval queries: 4/4 still correct, confidence
  tiers back to reading `high` for clean matches.

**What this doesn't fix:**
- One measurement on one query, not a statistically rigorous recalibration
  across a large, diverse eval set.
- If you're deploying this for real (not a demo): re-run a broad eval batch
  against the smaller models and re-tune from there.
- Or just pay for enough RAM to run the bigger models and skip this tradeoff
  entirely.

## Guardrails

Three layers, in order:

1. **Pre-generation refusal**: if no retrieved chunk is confident, or the top
   blended score is below `REFUSAL_FLOOR` (0.3), the request refuses
   immediately with `"Not found in document."` and **never calls the LLM**
   (saves latency and cost on obviously unanswerable questions).
2. **Grounded system prompt**
   - The LLM is instructed to answer only from the provided context.
   - Treats that context (and conversation history) as untrusted data rather
     than instructions: a prompt-injection guard against content embedded in
     the document, or a user message trying to get the model to ignore its
     instructions.
   - Responds with the exact refusal string when the context doesn't answer
     the question.
   - This prompt grew substantially through eval-driven testing this
     session; see [Failure cases found and
     fixed](#failure-cases-found-and-fixed) for the concrete failures each
     addition closes.
3. **Post-generation grounding verifier**
   - A second, independent LLM call checks the generated answer's claims
     against the retrieved source text.
   - Returns a verdict: `supported` / `partially_supported` / `unsupported`.
   - An `unsupported` verdict flips the answer to a refusal, even if the
     first model produced fluent text.
   - The verifier call has an 8-second timeout. On timeout or a malformed
     response it degrades to a neutral confidence factor rather than
     blocking the request (`app/guardrails/grounding.py`).

## Confidence scoring

```
confidence = 0.5 · retrieval + 0.2 · agreement + 0.3 · grounding
```

- **retrieval**: the top chunk's blended relevance score.
- **agreement**: fraction of returned chunks that were marked confident.
- **grounding**: 1.0 supported / 0.6 partially supported / 0.2 unsupported /
  0.5 neutral (verifier didn't run).

- Tiers: `high` ≥ 0.75, `medium` ≥ 0.5, else `low`.
- The `confidence_breakdown` field in every `/ask` response exposes the
  three components separately, so the UI can explain *why* a score landed
  where it did, not just the final number.
- Also makes a hallucinated-sounding "89% confident" next to a non-answer
  catchable. Treated as an anti-pattern in the frontend: a refusal never
  shows a percentage at all (see `ConfidenceScore.tsx`).

**Calibration note:**
- These weights and thresholds were tuned against the sample documents in
  `sample/` and the eval rounds described below.
- A reasonable starting point, not a universally correct answer.
- Already re-tuned once this session (see [the embedding/reranker section
  above](#the-embeddingreranker-model-and-why-it-changed)).
- Recalibrate again against a larger, more diverse document set before
  relying on this in production.

## Structured extraction

- The full document text (all pages concatenated, capped at 60k characters,
  well within Groq's 128k context) is sent to the LLM with a
  structured-output schema for the 13 shipment fields.
- The prompt instructs the model to return a field only if it's explicitly
  present in the text, `null` otherwise.
- Normalizes dates to ISO 8601 *using only the precision the document
  actually gives*.
- This exact wording exists because the first version fabricated
  `T00:00:00` onto date-only fields (see below).

## Failure cases found and fixed

- The RAG answer-quality work happened as an iterative eval loop
  (`EVAL_LOOP.md`).
- Generate a batch of questions across every 1/2/3-document upload
  combination.
- Write reference answers grounded in the actual sample PDFs.
- Run them against the live API, score retrieval and answer quality
  independently, and fix what's wrong.
- A few rounds of that turned up real bugs, not hypothetical ones:

- **Hallucinated a checkbox selection.**
  - A "Freight Charges: Collect / COD / Prepaid" field with no visual mark
    distinguishing the three options.
  - Asked which applied, the model confidently answered "Collect,"
    inventing a selection the text gives no evidence for.
  - Fixed by explicitly telling the prompt that plain reading order isn't a
    selection marker.
- **Answered from a placeholder instead of the real content.**
  - A document had both a real `carrier instructions: No weekend
    pickups...` line and a separately titled `Test RC Instructions`
    placeholder section.
  - Asked "what are the RC instructions," the model answered from the
    placeholder: its title lexically matched the question's wording more
    closely than the real content did.
  - Needed **three prompt iterations** before it reliably held: an abstract
    "prefer substance over placeholder" rule didn't work, a domain-specific
    version didn't fully work, and a concrete worked example mirroring the
    exact failure finally did.
  - This pattern repeated across several fixes this session: the model
    responds far more reliably to a concrete example than an abstract rule.
- **Wrong-party attribution.**
  - Asked "what's the customer's agreed amount" with only the carrier's
    rate confirmation uploaded (no shipper document).
  - The model answered with the carrier's amount: the only "Agreed Amount"
    field in context, under a "Carrier Details" table, silently reused for
    a different party's question.
  - Fixed by teaching the prompt that a value belongs to whichever section
    header it's actually under, regardless of the question's generic
    wording.
- **Stretched an unrelated sentence to answer a question.**
  - Asked "what are the carrier instructions" against a document that
    genuinely had no such section.
  - The model built an answer out of a generic pickup description that
    happened to contain the word "instructions" in passing ("follow
    on-site instructions at arrival").
  - Correct behavior is a refusal. Needed the same concrete-example
    treatment as above.
- **Over-refused an explicit `N/A` value.**
  - A document's `Class` field literally read `N/A`.
  - Asked "what class is the commodity," the model refused with "Not found
    in document."
  - Technically the field wasn't a *found* value, but `N/A` is the
    document's real, deliberate answer, not an absence.
  - Fixed by treating an explicit `N/A`/`None`/`-` as data to report, not
    grounds for refusal.
- **Retrieval discarded the right chunk before the LLM ever saw it.**
  - Asked about equipment type against a document with no field literally
    labeled "Equipment" (just `Flatbed:$1000.00 USD` inside a rate
    breakdown), the request refused: not a generation problem this time.
  - Direct inspection (`retrieve()` and `rerank()` called in isolation,
    bypassing the LLM) showed retrieval *did* surface the chunk, but
    `RELEVANCE_DROPOFF_RATIO` (then 0.4) discarded it.
  - With only 2 candidate chunks for that document, min-max normalization
    stretched a small raw-score gap into a full 0-1 spread, making a
    legitimately relevant #2 chunk look artificially worthless.
  - Fixed by dropping the ratio to 0.15, verified with a broad regression
    sweep since this constant affects every single query, not just the
    failing one.
- **Authorization bypass: explicit `document_ids` skipped session scoping.**
  - Found by an automated security review right before the public deploy,
    not the eval loop.
  - `/ask` and `/extract` both used a caller-supplied `document_ids` list
    directly, with no check that those IDs belonged to the requesting
    session.
  - Since `document_id` is just a content hash (visible in every `/upload`
    response, not a secret), any session could pull Q&A answers or
    extracted data out of a document a *different* session uploaded, just
    by naming its ID.
  - A companion endpoint (`GET /documents/{id}/file`, serving raw file
    bytes) had a related gap: it fell back to *unscoped* access whenever
    the caller simply omitted `X-Session-Id`.
  - Since that header is entirely client-controlled with no server-side
    verification, "no header" is indistinguishable from "attacker stripped
    the header on purpose."
  - Fixed by intersecting `document_ids` against the session's
    actually-visible documents, and requiring a session unconditionally for
    the raw-file endpoint specifically (it's the most sensitive thing the
    API serves).
  - Verified with real cross-session curl tests, not just code review.

Failure cases that remain open, by design or by not-yet-tested:

- **OCR quality.**
  - pytesseract runs on scanned PDFs and image uploads, but this was never
    stress-tested this session (no scanned/image sample docs existed).
  - A blurry photo, skewed scan, or handwriting can yield zero readable
    text, in which case `/upload` returns a 422.
- **Ambiguous or locale-formatted dates.**
  - Extraction normalizes to ISO 8601 on a best-effort basis.
  - A genuinely ambiguous date (`03/04/2026`) may be mis-parsed as
    month/day vs. day/month.
- **Table-mangled text.**
  - pymupdf's plain-text extraction usually preserves reading order, but
    densely nested tables can interleave columns.
  - DOCX table handling is explicit (row-joined). PDF tables rely on
    pymupdf's default layout heuristics, with no `find_tables()` fallback
    yet.
- **Confidence calibration is a single-sample measurement**, not a
  statistically broad one. See the caveat in the [model-switch section
  above](#the-embeddingreranker-model-and-why-it-changed).

## Improvement ideas

- Broader, statistically meaningful confidence-threshold calibration for
  the smaller embedding/reranker pair. The current one is a single measured
  query, not a distribution.
- Retrieval tuning specifically for values embedded in unlabeled inline text
  (the equipment-type/rate-breakdown case).
  - Current fix: a prompt instruction plus a global dropoff-ratio change.
  - A more targeted retrieval signal (e.g. boosting short label-like spans
    before a colon/dollar amount) would be more precise.
- OCR'd image/scanned-document testing. Genuinely untested this session, no
  representative sample existed.
- Hybrid retrieval (dense + BM25) fused with reciprocal rank fusion, for
  documents where keyword match matters more than semantic similarity.
- Table-aware PDF parsing (`page.find_tables()`) instead of relying on plain
  text extraction order.
- Stream `/ask` responses over SSE instead of returning the full answer at
  once.
- Multi-tenant hosting: swap the embedded Chroma `PersistentClient` for a
  server-mode deployment, and the filesystem document registry for a proper
  database, once this moves beyond a single-instance deployment. Doubly true
  now that Render's free tier has no persistent disk at all.
- A real automated CI eval (the golden set in `scripts/eval_golden.yaml`, or
  a distilled version of the manual eval-loop rounds) gating deploys, rather
  than a manual round each time the model or prompt changes.

## Security

- **Session scoping is a convenience boundary, not authentication.**
  - `X-Session-Id` is a client-generated, unverified string. There's no
    login, no server-side session table proving ownership.
  - Stops one browser tab from casually seeing another session's uploads.
    Does not stop a determined caller who inspects network requests.
  - Don't point this at genuinely sensitive documents without adding real
    auth first.
- `document_ids` passed to `/ask`/`/extract` are intersected against the
  requesting session's visible documents (see [Failure
  cases](#failure-cases-found-and-fixed) above for the bug this fixes).
- `GET /documents/{id}/file` always requires a resolvable session. The one
  endpoint that doesn't have an "unscoped caller" fallback, since it serves
  raw file bytes rather than derived Q&A/extraction output.
- CORS is an explicit origin allowlist (`app_factory.py`) plus a regex for
  Vercel preview deployments, not `allow_origins=["*"]`.

## Eval results

- `scripts/run_eval.py` runs a small golden Q&A set
  (`scripts/eval_golden.yaml`) against the generated sample documents.
- A mix of answerable questions, deliberately unanswerable questions, and a
  cross-document question.
- Checks refusal behavior and answer correctness.
- This is a fast smoke test. The substantive eval work (the failures
  actually found and fixed) happened in manual rounds against the live API,
  described above.

```
Question                                               Result     Check  Tier
-------------------------------------------------------------------------------
What is the agreed rate for this shipment?             answered   PASS   high
Who is the carrier?                                    answered   PASS   high
What is the pickup date and time?                      answered   PASS   high
What is the total weight of the shipment?               answered   PASS   high
Who is the CEO of the shipper company?                  refused    PASS   high
What is the weather forecast for the delivery city?     refused    PASS   high
What is the carrier name?                               answered   PASS   high
What is the agreed rate for this shipment?               refused    PASS   high
-------------------------------------------------------------------------------
Accuracy: 8/8 (100%)
```

Re-run after any threshold change: `cd apps/api && PYTHONPATH=. uv run python scripts/run_eval.py`.

## Project structure

```
apps/
  api/    FastAPI backend: see apps/api/app for the module layout
  web/    Next.js frontend: see apps/web/src/features/doc-chat
docs/
  architecture.drawio   Editable deployment-architecture diagram
  RUNBOOK.md            Operations runbook (incidents, backups, rollback, logs)
render.yaml             Render Blueprint (Docker backend, free tier)
docker-compose.yml      Local stack behind nginx (https://localhost)
nginx/                  Reverse proxy config (TLS, /api routing, rate limit)
terraform/docker/       Docker provider: network, volume, api/web/nginx/LocalStack
terraform/aws-local/    AWS provider on LocalStack: backup bucket + IAM user
scripts/                VM setup, backup/restore, healthcheck, cert generation
.github/workflows/      CI (pull requests) and deploy (push to main)
mise.toml               Pinned toolchain + `mise run dev` (backend + frontend together)
```

## Development

```bash
# Backend gates
cd apps/api && uv run ruff check . && uv run mypy app && uv run pytest

# Frontend gates
cd apps/web && pnpm lint && pnpm type-check
```
