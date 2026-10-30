# syntax=docker/dockerfile:1.7
# shop-worker : builder -> test -> runtime, identifiants PyPI via secret mount (jamais dans une couche)

FROM python:3.12.16-slim-bookworm AS builder
ARG TARGETARCH
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
WORKDIR /app
COPY requirements.txt ./
# pip.conf monté le temps de cette seule commande ; cache pip isolé par architecture
# (DL3042 ignoré : faux positif, le cache pip est un cache mount BuildKit, absent de l'image)
# hadolint ignore=DL3042
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH} \
    pip install -r requirements.txt

FROM builder AS test
ARG TARGETARCH
COPY requirements-dev.txt ./
# hadolint ignore=DL3042
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH} \
    pip install -r requirements-dev.txt
COPY worker ./worker
COPY tests ./tests
RUN ruff check worker tests && python -m pytest -q tests && touch /tmp/tests-passed

FROM python:3.12.16-slim-bookworm AS runtime
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    METRICS_PORT=9100
RUN groupadd -g 10001 worker && useradd -u 10001 -g worker -M -s /usr/sbin/nologin worker
WORKDIR /app
COPY --from=test /tmp/tests-passed /tmp/tests-passed
COPY --from=builder /opt/venv /opt/venv
COPY worker ./worker
ARG VERSION=dev
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="shop-worker" \
      org.opencontainers.image.description="Consommateur de la file orders:queue (Shop SAS)" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/shop-sas/shop-worker"
USER worker
EXPOSE 9100
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request,os; urllib.request.urlopen('http://127.0.0.1:'+os.getenv('METRICS_PORT','9100')+'/metrics', timeout=2)"]
CMD ["python", "-m", "worker.main"]
