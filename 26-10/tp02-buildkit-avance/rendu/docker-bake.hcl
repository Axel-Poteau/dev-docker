# docker buildx bake — construit toute la stack Shop SAS (API du TP01 + worker) en une commande
#   docker buildx bake --print
#   VERSION=1.0 GIT_SHA=$(git rev-parse --short HEAD) docker buildx bake worker-test
#   VERSION=1.0 docker buildx bake --set '*.platform=linux/amd64' --load

variable "VERSION" {
  default = "dev"
}

variable "GIT_SHA" {
  default = "unknown"
}

variable "REGISTRY" {
  default = "localhost:5000"
}

group "default" {
  targets = ["api", "worker"]
}

# Cible abstraite : jamais construite seule, héritée par les autres
target "_common" {
  platforms = ["linux/amd64", "linux/arm64"]
  labels = {
    "org.opencontainers.image.vendor"   = "Shop SAS"
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = GIT_SHA
  }
  args = {
    GIT_SHA = GIT_SHA
  }
}

target "api" {
  inherits   = ["_common"]
  context    = "../../tp01-optimisation-image/rendu/shopapi"
  dockerfile = "Dockerfile"
  args = {
    APP_VERSION = VERSION
  }
  tags       = ["${REGISTRY}/shopapi:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/cache:api"]
  cache-to   = ["type=registry,ref=${REGISTRY}/cache:api,mode=max"]
}

target "worker" {
  inherits   = ["_common"]
  context    = "shop-worker"
  dockerfile = "Dockerfile"
  args = {
    VERSION = VERSION
  }
  secret     = ["id=pipconf,src=shop-worker/pip.conf"]
  tags       = ["${REGISTRY}/shop-worker:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/cache:worker"]
  cache-to   = ["type=registry,ref=${REGISTRY}/cache:worker,mode=max"]
}

# Exécute uniquement l'étape test (lint + pytest), sans produire d'image
target "worker-test" {
  inherits  = ["worker"]
  target    = "test"
  platforms = ["linux/amd64"]
  tags      = []
  cache-to  = []
  output    = ["type=cacheonly"]
}
