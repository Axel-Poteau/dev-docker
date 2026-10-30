<?php
require_once __DIR__ . '/config.php';

function db(): PDO {
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO('mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=utf8mb4', DB_USER, DB_PASS, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
    }
    return $pdo;
}

// Une ligne JSON par événement sur stderr (LOG_FILE=php://stderr) : collectée par Docker, puis Loki
function app_log(string $level, string $msg): void {
    $line = json_encode(['time' => date('c'), 'level' => strtolower($level), 'app' => 'geststock', 'msg' => $msg],
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n";
    @file_put_contents(LOG_FILE, $line, FILE_APPEND);
}
