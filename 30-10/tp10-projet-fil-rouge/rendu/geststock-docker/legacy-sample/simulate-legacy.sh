#!/usr/bin/env bash
# simulate-legacy.sh — fabrique ce que l'ancien serveur nous livre : un mysqldump fait par MariaDB 10.3
# (version de Debian 10) et l'archive de /var/www/html/uploads. Sortie : legacy-sample/out/
set -euo pipefail
cd "$(dirname "$0")"
OUT=out; rm -rf "$OUT"; mkdir -p "$OUT/uploads"
NAME=geststock-legacy-sim
docker rm -f $NAME >/dev/null 2>&1 || true

# photos « historiques » : PNG générés, nommés comme le faisait index.php (uniqid('p_', true))
python3 - "$OUT/uploads" <<'PY'
import sys, zlib, struct, os
def png(rgb):
    c = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    raw = b"".join(b"\x00" + bytes(rgb) * 16 for _ in range(16))
    return b"\x89PNG\r\n\x1a\n" + c(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) + c(b"IDAT", zlib.compress(raw)) + c(b"IEND", b"")
for name, rgb in [("p_5a1c2e0f3b7d41.10293847.png", (200, 30, 30)), ("p_5c8e91aa04f2e3.56473829.png", (30, 160, 60)),
                  ("p_60b3f5d2c19a77.83746152.jpg", (30, 60, 200)), ("p_6123ab45cd6789.19283746.png", (240, 200, 0))]:
    open(os.path.join(sys.argv[1], name), "wb").write(png(rgb))
PY

docker run -d --name $NAME -e MYSQL_ROOT_PASSWORD=legacy -e MYSQL_DATABASE=geststock mariadb:10.3.39 >/dev/null
# attendre le serveur définitif (le premier « ready » est celui de l'initialisation, sans réseau)
for _ in $(seq 90); do docker logs $NAME 2>&1 | grep -q "ready for connections.*port: 3306" && break; sleep 1; done
{ cat ../app/sql/schema.sql; cat <<'SQL'
INSERT INTO items(name, qty, photo, created_at) VALUES
 ('Écran 24" Dell', 7, 'p_5a1c2e0f3b7d41.10293847.png', '2017-11-27 09:12:00'),
 ('Clavier AZERTY', 25, 'p_5c8e91aa04f2e3.56473829.png', '2019-03-17 14:02:11'),
 ('Souris ergonomique', 4, 'p_60b3f5d2c19a77.83746152.jpg', '2021-05-30 16:45:09'),
 ('Station d''accueil Thunderbolt', 1, 'p_6123ab45cd6789.19283746.png', '2021-08-23 11:30:42'),
 ('Câble RJ45 cat6 5m', 140, NULL, '2022-01-05 08:00:00'),
 ('Adaptateur USB-C → HDMI', 0, NULL, '2023-02-14 10:10:10');
DELETE FROM items WHERE name = 'Batterie externe';
SQL
} | docker exec -i $NAME mysql -uroot -plegacy geststock
docker exec $NAME mysqldump -uroot -plegacy --single-transaction --default-character-set=utf8mb4 geststock > "$OUT/geststock-dump.sql"
tar -C "$OUT/uploads" -czf "$OUT/uploads.tar.gz" . && rm -rf "$OUT/uploads"
( cd "$OUT" && sha256sum geststock-dump.sql uploads.tar.gz > SHA256SUMS )
echo "legacy : $(docker exec $NAME mysql -uroot -plegacy -N -e 'SELECT VERSION(), (SELECT count(*) FROM geststock.items)' | tr '\t' ' ') articles"
docker rm -f $NAME >/dev/null
ls -l "$OUT"; head -3 "$OUT/geststock-dump.sql"
