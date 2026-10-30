<?php
// Configuration par variables d'environnement (conteneurisation 2026).
// Valeurs par défaut = stack compose ; aucun mot de passe ici : DB_PASS vient d'un secret fichier.
function cfg(string $name, string $default): string
{
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
}

// <NOM>_FILE prioritaire (secret Docker monté dans /run/secrets), sinon variable <NOM>
function cfg_secret(string $name): string
{
    $file = getenv($name . '_FILE');
    if ($file !== false && $file !== '') {
        $value = @file_get_contents($file);
        if ($value === false) {
            throw new RuntimeException("secret $name illisible : $file");
        }
        return rtrim($value, "\r\n");
    }
    return cfg($name, '');
}

define('DB_HOST', cfg('DB_HOST', 'db'));
define('DB_NAME', cfg('DB_NAME', 'geststock'));
define('DB_USER', cfg('DB_USER', 'geststock'));
define('DB_PASS', cfg_secret('DB_PASS'));
define('UPLOAD_DIR', rtrim(cfg('UPLOAD_DIR', '/var/www/uploads'), '/') . '/');
define('LOG_FILE', cfg('LOG_FILE', 'php://stderr'));
define('SMTP_HOST', cfg('SMTP_HOST', 'mailpit'));
define('REPORT_TO', cfg('REPORT_TO', 'direction@shop.example'));
