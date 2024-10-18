#!/usr/bin/env php
<?php

declare(strict_types=1);

// Constants
const MIN_PHP_VERSION = '8.0.0';
const PICKLE_URL = 'https://github.com/FriendsOfPHP/pickle/releases/latest/download/pickle.phar';
const COMPOSER_URL = 'https://getcomposer.org/download/latest-stable/composer.phar';

// Configuration
$dependencies = ['guzzlehttp/guzzle'];
$opentelemetry_packages = [
    'open-telemetry/api',
    'open-telemetry/sdk',
    'open-telemetry/exporter-otlp',
    'open-telemetry/opentelemetry-auto-laravel',
    'open-telemetry/extension-propagator-b3',
    'Middleware/laravel-apm'
];

// Main execution
if ($argc < 2) {
    usage($argv[0]);
    exit(1);
}

try {
    match ($argv[1]) {
        'install' => install($dependencies, $opentelemetry_packages),
        'run' => run(array_slice($argv, 2)),
        default => throw new InvalidArgumentException("Invalid mode"),
    };
} catch (Exception $e) {
    colorLog($e->getMessage(), 'e');
    usage($argv[0]);
    exit(1);
}

// Functions
function install(array $dependencies, array $packages): void
{
    check_preconditions();
    make_basic_setup($dependencies, $packages);
    cleanup_files(['pickle.phar', 'composer.phar']);

    if (check_postconditions()) {
        colorLog("Middleware APM has been successfully installed", 's');
    }
}

function run(array $command_parts): void
{
    if (empty($command_parts)) {
        throw new InvalidArgumentException("No command provided for 'run' mode");
    }
    set_env();
    $command = implode(' ', $command_parts);
    passthru($command, $result_code);
    exit($result_code);
}

function check_extensions() {
    $flag = false;
    
    $extensions = [
        'zlib',
        'mbstring',
        'simplexml',
        'json',
        'dom',
        'openssl',
        'phar',
        'fileinfo',
        'pcre',
        'xmlwriter',
        'gd'
    ];

    colorLog("Checking PHP extensions...");

    foreach ($extensions as $extension) {
        if (!extension_loaded($extension)) {
            colorLog("$extension: Not installed", "w");
            $flag = true;
        }
    }

    if ($flag) {
        throw new RuntimeException("\nPlease install the above mentioned extensions first.");
    }
    colorLog("All required extensions are installed");
}

function check_preconditions(): void
{
    if (version_compare(PHP_VERSION, MIN_PHP_VERSION, '<')) {
        throw new RuntimeException("PHP " . MIN_PHP_VERSION . " or higher is required");
    }
    check_extensions();
    ensure_composer();
    if (!command_exists('phpize')) {
        throw new RuntimeException('php-sdk (php-dev) is not installed');
    }
    if (!file_exists('composer.json')) {
        throw new RuntimeException('Project does not contain composer.json');
    }
    download_file(PICKLE_URL, 'pickle.phar');
    make_executable('pickle.phar');
}

function ensure_composer(): void
{
    $composer_path = getenv('COMPOSER_PATH');
    if (empty($composer_path) && !command_exists('composer')) {
        colorLog("Composer not found. Downloading composer.phar...", 'i');
        download_file(COMPOSER_URL, 'composer.phar');
        make_executable('composer.phar');
        colorLog("Composer downloaded successfully.", 's');
    }
}

function download_file(string $url, string $destination): void
{
    $max_attempts = 3;
    $attempt = 0;
    while ($attempt < $max_attempts) {
        try {
            $content = file_get_contents($url);
            if ($content === false) {
                throw new RuntimeException("Failed to download file from $url");
            }
            if (file_put_contents($destination, $content) === false) {
                throw new RuntimeException("Failed to write file to $destination");
            }
            return;
        } catch (Exception $e) {
            $attempt++;
            if ($attempt >= $max_attempts) {
                throw new RuntimeException("Failed to download file after $max_attempts attempts: " . $e->getMessage());
            }
            colorLog("Download attempt $attempt failed. Retrying...", 'w');
            sleep(2);
        }
    }
}

function make_executable(string $file): void
{
    if (PHP_OS_FAMILY !== 'Windows') {
        if (!chmod($file, 0755)) {
            throw new RuntimeException("Failed to make $file executable");
        }
    }
}

function get_composer_command(): string
{
    $composer_path = getenv('COMPOSER_PATH');
    if (!empty($composer_path)) {
        return $composer_path;
    }
    if (command_exists('composer')) {
        return 'composer';
    }
    return 'php composer.phar';
}

function is_opentelemetry_installed(): bool
{
    $modules = explode("\n", shell_exec('php -m') ?: '');
    return in_array('opentelemetry', $modules);
}

function make_basic_setup(array $dependencies, array $packages): void
{
    if (!is_opentelemetry_installed()) {
        execute_command("php pickle.phar install opentelemetry -n");
        create_ini_file(trim(shell_exec('php-config --ini-dir')));
    }

    $composer = get_composer_command();
    execute_command("$composer config --no-plugins allow-plugins.php-http/discovery false --no-interaction");
    execute_command("$composer config minimum-stability dev --no-interaction");

    $require_cmd = "$composer require " . implode(' ', $dependencies) . " " .
        implode(' ', array_map(fn($pkg) => "$pkg", $packages)) .
        " --with-all-dependencies --no-interaction";

    execute_command($require_cmd);
}

function cleanup_files(array $files): void
{
    foreach ($files as $file) {
        if (file_exists($file)) {
            if (!unlink($file)) {
                colorLog("Warning: Failed to remove temporary file: $file", 'w');
            } else {
                colorLog("Removed temporary file: $file", 'i');
            }
        }
    }
}

function check_postconditions(): bool
{
    $extension_file = PHP_OS_FAMILY === 'Windows' ? '\php_opentelemetry.dll' : '/opentelemetry.so';
    $php_info = array();
    $res_code = null;

    exec('php -i', $php_info, $res_code);

    if ($res_code !== 0) {
        colorLog("Failed to get PHP info", 'e');
        return false;
    }

    $ext_dir_line = null;

    foreach ($php_info as $line) {
        if (preg_match('/^extension_dir => (.*)$/', $line, $matches)) {
            $ext_dir_line = trim($matches[1]);
            break;
        }
    }

    if ($ext_dir_line === null || !file_exists(explode(" ", $ext_dir_line)[0] . $extension_file)) {
        colorLog("ERROR: opentelemetry has not been installed correctly", 'e');
        return false;
    }

    if (!in_array('opentelemetry', explode("\n", shell_exec('php -m')))) {
        colorLog("ERROR: opentelemetry extension has not been added to ini file", 'e');
        return false;
    }

    return true;
}

function set_env(): void
{
    $env_vars = [
        'OTEL_PHP_AUTOLOAD_ENABLED' => getenv('OTEL_PHP_AUTOLOAD_ENABLED') ?: 'true',
        'OTEL_TRACES_EXPORTER' => getenv('OTEL_TRACES_EXPORTER') ?: 'otlp',
        'OTEL_EXPORTER_OTLP_PROTOCOL' => getenv('OTEL_EXPORTER_OTLP_PROTOCOL') ?: 'http/json',
        'OTEL_PROPAGATORS' => getenv('OTEL_PROPAGATORS') ?: 'baggage,tracecontext',
        'OTEL_SERVICE_NAME' => getenv("OTEL_SERVICE_NAME") ?: getenv('MW_SERVICE_NAME') ?: 'service-' . getmypid(),
        'OTEL_EXPORTER_OTLP_ENDPOINT' => getenv("OTEL_EXPORTER_OTLP_ENDPOINT") ?: getenv("MW_TARGET")  ?: 'http://localhost:9320'
    ];

    foreach ($env_vars as $key => $value) {
        if (empty(getenv($key))) {
            putenv("$key=$value");
        }
    }
}

// Utility functions
function command_exists(string $command): bool
{
    return !empty(getCmdOutput($command));
}

function getCmdOutput(string $cmd)
{
    $os_cmd = PHP_OS_FAMILY === 'Windows' ? 'where' : 'command -v';
    $output = shell_exec("$os_cmd $cmd");
    return $output === null ? "" : trim($output);
}

function colorLog(string $message, string $type = 'i'): void
{
    $colors = ['e' => '31', 's' => '32', 'w' => '33', 'i' => '36'];
    $color = $colors[$type] ?? '0';
    echo "\033[{$color}m$message\033[0m\n";
}

function create_ini_file(string $ini_dir): void
{
    $ini_files = [];
    $cliIni =  $ini_dir . DIRECTORY_SEPARATOR . 'opentelemetry.ini';
    array_push($ini_files, $ini_dir . DIRECTORY_SEPARATOR . 'opentelemetry.ini');
    if (file_exists($cliIni)) {
        return;
    }

    if (strpos($ini_dir, '/cli/conf.d') !== false) {
        $apacheConfd = str_replace('/cli/conf.d', '/apache2/conf.d', $ini_dir);
        $apacheIni =  $apacheConfd . DIRECTORY_SEPARATOR . 'opentelemetry.ini';
        if (file_exists($apacheConfd) && !file_exists($apacheIni)) {
            array_push($ini_files, $apacheConfd . DIRECTORY_SEPARATOR . 'opentelemetry.ini');
        }

        $fpmConfd = str_replace('/cli/conf.d', '/fpm/conf.d', $ini_dir);
        if (file_exists(($fpmConfd))) {
            array_push($ini_files, $fpmConfd . DIRECTORY_SEPARATOR . 'opentelemetry.ini');
        }
    }

    $content = PHP_OS_FAMILY === 'Windows' ? 'extension=php_opentelemetry.dll' : 'extension=opentelemetry.so';

    foreach ($ini_files as $filename) {
        if (file_put_contents($filename, $content) === false) {
            throw new RuntimeException("Failed to write to INI file: $filename");
        }
    }
}

function execute_command(string $cmd): void
{
    colorLog($cmd);
    passthru($cmd, $result_code);
    if ($result_code > 0) {
        throw new RuntimeException("Command failed with exit code {$result_code}");
    }
}

function usage(string $script_name): void
{
    colorLog("Usage: $script_name install");
}