# TP07 — Observabilité : logs, métriques, alertes

Stack lancée à côté de celle du TP04 (projet `shop`, `HTTP_PORT=8088`) :

```bash
docker compose -f compose.observability.yml up -d --wait
./load.sh 2000 20            # MIX=1 : + POST /orders et 404
```

Prometheus `http://127.0.0.1:9090`, Grafana `http://127.0.0.1:3001` (admin/admin, lecture anonyme : lab uniquement).

| Fichier | Rôle |
|---|---|
| [`compose.observability.yml`](compose.observability.yml) | Prometheus, cAdvisor, docker-meta, Loki, Promtail, Grafana ; rejoint `shop_front` / `shop_back` (`external`) |
| [`prometheus/prometheus.yml`](prometheus/prometheus.yml), [`prometheus/alerts.yml`](prometheus/alerts.yml) | scrape (découverte DNS api/worker, cAdvisor, docker-meta), 6 alertes (`promtool check` : `SUCCESS: 6 rules found`) |
| [`promtail/promtail.yml`](promtail/promtail.yml), [`loki/loki.yml`](loki/loki.yml) | collecte de tous les logs par `docker_sd_configs`, labels `container`/`service`/`project`/`stream`/`level` |
| [`grafana/`](grafana/) | sources et tableau de bord [`shop.json`](grafana/dashboards/shop.json) **provisionnés par fichiers** (15 panneaux) |
| [`docker-meta/docker_meta.py`](docker-meta/docker_meta.py) | exporteur maison : nom/service par id, restarts, OOMKilled, santé (voir §3) |
| [`load.sh`](load.sh) | charge avec `hey` depuis `shop_front` |
| Transcripts | `etape1-logs.txt`, `etape2-metriques.txt`, `etape3-verification.txt`, `etape4-panne1-db-arretee.txt`, `etape4-panne2-mot-de-passe.txt` |
| Captures | [`captures/alertes-firing.png`](captures/alertes-firing.png), [`captures/prometheus-requetes-par-code.png`](captures/prometheus-requetes-par-code.png) |

## 1. Logs côté Docker (`etape1-logs.txt`)

- `docker logs --timestamps shop-api-1 | jq` : logs pino JSON (`level` 30 = info, 50 = error, `responseTime`, `req.url`).
- `LogConfig` = `json-file`, `max-size 10m`, `max-file 3` (rotation posée au TP04).
- Le fichier `<id>-json.log` est dans `/var/lib/docker/containers/<id>/`, dans la VM Docker Desktop (lu via `nsenter`). Chaque ligne y est ré-encapsulée (`{"log":"…\n","stream":"stdout","time":…}`).
- `--log-driver none` : `docker logs` → `configured logging driver does not support reading`.

**Sans `max-size` pendant 6 mois** : le fichier grossit sans limite et finit par remplir `/var/lib/docker`. Le daemon
et **tous** les conteneurs tombent alors (plus d'écriture possible, base comprise). Le plus gros fichier de la VM fait
déjà 6,2 Mo après deux jours de TP.

**stdout/stderr plutôt qu'un fichier** : le runtime collecte, horodate et fait tourner les logs, et `docker logs` et les
collecteurs (Promtail) les lisent sans rien savoir de l'application. Un fichier dans le conteneur se perd avec la
couche inscriptible, n'a pas de rotation et doit être monté pour être lu.

| Driver | Usage |
|---|---|
| `json-file` | défaut, lisible par `docker logs`, rotation à configurer |
| `local` | format binaire compressé, rotation par défaut, plus compact ; `docker logs` fonctionne |
| `journald` | intégré à systemd (`journalctl CONTAINER_NAME=…`), centralisé avec les logs de l'hôte |
| `fluentd` / `awslogs` | envoi direct vers un collecteur ou CloudWatch ; collecteur indisponible = blocage ou perte |

`mode: non-blocking` + `max-buffer-size` : l'application n'est jamais bloquée par un driver lent (en `blocking`, un
`fluentd` injoignable fige les `write()` de l'appli). En contrepartie, quand le tampon est plein, **des lignes sont
perdues** sans erreur. Il faut choisir entre disponibilité et exhaustivité des logs.

## 2. Métriques côté Docker (`etape2-metriques.txt`)

- `docker stats` : api 56 Mio, proxy 40 Mio, worker 20 Mio, db 11 Mio, redis 3 Mio. `docker system df` : 22,7 Go d'images
  (58 % récupérables), `shop_pgdata` 73 Mo.
- **OOM** : `docker update --memory 64m --memory-swap 64m shop-api-1` puis `./load.sh 20000 100`. Événements :
  `16:50:58 health_status: unhealthy` puis `16:51:16 oom`, et `OOMKilled=true`, **mais `RestartCount=0`**.
  - Cause : en dev, l'API tourne sous `node --watch` (override du TP04). L'OOM killer tue le processus **enfant**
    (`pid 12`), le superviseur `--watch` reste en PID 1 et affiche `Failed running 'src/server.js'`. Il attend un
    changement de fichier pour relancer : le conteneur reste `running`/`unhealthy` **sans servir**, et la politique
    `restart` ne se déclenche jamais.
  - En prod (`CMD node src/server.js` en PID 1), c'est le conteneur entier qui est tué puis redémarré
    (`unless-stopped`), et `RestartCount` augmente.
  - Enseignement : **un healthcheck `unhealthy` ne redémarre rien** avec Docker seul. Il faut l'alerte (ou un orchestrateur).

## 3. Stack d'observabilité (`etape3-verification.txt`)

**Prometheus** (`id` → `uid=65534(nobody)`) :

- `dns_sd_configs` sur `api:3000` et `worker:9100` : une cible par adresse renvoyée par le DNS embarqué, donc
  **tous les réplicas**, sans accès à Docker.
- **Pourquoi pas `docker_sd_configs`** : Prometheus tourne en `nobody` et ne peut pas lire la socket (root:docker 660).
  Il faudrait le lancer en root ou lui monter la socket, et accès à la socket = root sur l'hôte. Ça ferait d'un serveur
  web exposé (9090) un point d'entrée vers tout l'hôte.

**cAdvisor sur Docker Desktop** : avec le *containerd image store*, la fabrique docker de cAdvisor échoue. J'utilise la
fabrique « raw » (`/docker/<id>`), qui ne donne pas de nom. D'où **`docker-meta`**, un exporteur de 60 lignes
(Python stdlib, socket en lecture), qui publie `docker_container_info{id,name,service,project}`. La jointure
`* on (id) group_left (name) docker_container_info` retrouve les noms (`shop-api-1` 5,9 Mo…). Il expose aussi
`restart_count`, `oom_killed` et `healthy`, que cAdvisor ne fournit pas.

**Loki + Promtail** : `docker_sd_configs` (Promtail est le **seul** composant qui a la socket, en lecture). Les labels
`service`/`project` viennent des labels compose, et l'étape `json` extrait `level` (30/50 pour pino, INFO/ERROR pour
le worker). Services vus : api, db, proxy, redis… et tous les autres projets de la machine.

**Grafana** : sources (`uid` fixes) et tableau « Shop SAS — vue d'ensemble » chargés depuis les fichiers
(`allowUiUpdates: false`), sans aucun clic. Panneaux : réplicas up, req/s, % 5xx, p95, alertes actives,
commandes/min, req/s par code, latence p50/p95/p99, mémoire et CPU par conteneur avec la limite, réseau,
restarts/OOM, worker, logs d'erreur Loki, volume de logs par service et niveau.

**Alertes** ([`alerts.yml`](prometheus/alerts.yml)) : `ApiDown` (`up == 0 or absent()`), `ApiErreurs5xx` (> 5 %),
`ApiLatenceP95` (> 500 ms), `ConteneurRedemarre` (`increase(restart_count[5m]) > 0`), `ConteneurOOMKilled`,
`MemoireProcheLimite` (working set / limite > 90 %). Vues en `firing` pendant le TP : `ApiDown` et `ConteneurOOMKilled`
(étape 2), `ApiErreurs5xx` (panne 2, [capture](captures/alertes-firing.png)).

Requêtes du sujet : `{service="api"} | json | level="50"` → `password authentication failed for user "shop"` (panne 2) ;
`sum(rate(http_request_duration_seconds_count[1m])) by (status)` → [capture](captures/prometheus-requetes-par-code.png)
(pic de 200 sous charge à 15:56, puis 500 pendant les pannes).

## 4. Exercice de corrélation

Je n'avais pas de formateur pour injecter les pannes : je les ai injectées moi-même, puis j'ai fait le diagnostic
**uniquement** avec Prometheus et Loki, avant de confirmer avec `docker`.

**Panne 1 : base arrêtée sous charge** (`etape4-panne1-db-arretee.txt`). Diagnostic en ~1 min :

- `ApiDown` firing, `docker_container_healthy{name="shop-api-1"} = 0` ;
- `absent(… {name="shop-db-1"}) = 1` : **plus aucune métrique cAdvisor pour la base**, le conteneur n'existe plus en
  tant que processus ;
- confirmation : `shop-db-1 Exited (0)`.

Découverte au passage : l'API n'est pas seulement en erreur, elle **plante**. Le pool `pg` émet un événement `error`
non géré sur une connexion inactive coupée (`57P01 terminating connection due to administrator command`), et sous
`node --watch` elle n'est pas relancée. À remonter aux devs : `pool.on('error', …)`.

**Panne 2 : mot de passe BDD changé** (`ALTER USER shop PASSWORD …` puis redémarrage de l'API,
`etape4-panne2-mot-de-passe.txt`). Diagnostic en < 1 min :

1. alerte `ApiErreurs5xx` : 97 % de 5xx ;
2. req/s par code : 41,6/s de `500`, 0,1/s de `200` ;
3. Loki, erreurs de l'API : `password authentication failed for user "shop"`, et 2 436 lignes côté `db` sur 5 min.
   Cause trouvée : identifiants, pas réseau (la base est `healthy`).

Remise en état : mot de passe restauré depuis le secret, API redémarrée, alertes retombées.

## Limites et écarts

- **Pas de capture du tableau de bord Grafana.** Chrome headless (alpine-chrome, puis puppeteer) renvoie une page
  blanche ou n'atteint jamais l'état « chargé », à cause du websocket Grafana Live. Le tableau est provisionné et ses
  requêtes ont été vérifiées par l'API ; la capture Prometheus du graphe par code HTTP le remplace.
- Bonus non traités.
- Le projet s'appelle `observability`, comme celui du TP10 : les volumes sont préfixés `tp07-` pour ne pas mélanger
  les données, et il ne faut pas faire tourner les deux en même temps.
