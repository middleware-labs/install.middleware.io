#!/usr/bin/env php
<?php

declare(strict_types=1);

// Constants
const MIN_PHP_VERSION = '8.0.0';
const PICKLE_URL = 'https://github.com/FriendsOfPHP/pickle/releases/latest/download/pickle.phar';

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
    unlink('pickle.phar');

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
        throw new RuntimeException("\nPlease install Above mentioned extensions first.");
    }
    colorLog("All required extensions are installed");
}

function check_preconditions(): void
{
    $composer_path = getenv('COMPOSER_PATH');
    if (version_compare(PHP_VERSION, MIN_PHP_VERSION, '<')) {
        throw new RuntimeException("PHP " . MIN_PHP_VERSION . " or higher is required");
    }
    check_extensions();
    if (empty($composer_path) && !command_exists('composer')) {
        throw new RuntimeException('composer is not installed');
    }
    if (!command_exists('phpize')) {
        throw new RuntimeException('php-sdk (php-dev) is not installed');
    }
    if (!file_exists('composer.json')) {
        throw new RuntimeException('Project does not contain composer.json');
    }
    file_put_contents('pickle.phar', file_get_contents(PICKLE_URL));
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

    // get full composer path
    $composer_path = getenv('COMPOSER_PATH');
    $composer = empty($composer_path) ? getCmdOutput("composer") : $composer_path;
    execute_command("$composer config --no-plugins allow-plugins.php-http/discovery false --no-interaction");
    execute_command("$composer config minimum-stability dev --no-interaction");

    $require_cmd = "$composer require " . implode(' ', $dependencies) . " " .
        implode(' ', array_map(fn($pkg) => "$pkg", $packages)) .
        " --with-all-dependencies --no-interaction";

    execute_command($require_cmd);
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

    if ($ext_dir_line == null || !file_exists(explode(" ", $ext_dir_line)[0] . $extension_file)) {
        colorLog("ERROR : opentelemetry has not been installed correctly", 'e');
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
  return trim(shell_exec("$os_cmd $cmd"));
}

function colorLog(string $message, string $type = 'i'): void
{
    $colors = ['e' => '31', 's' => '32', 'w' => '33', 'i' => '36'];
    $color = $colors[$type] ?? '0';
    echo "\033[{$color}m$message\033[0m\n";
}

function create_ini_file(string $ini_dir): void
{
    $filename = $ini_dir . DIRECTORY_SEPARATOR . 'opentelemetry.ini';
    if (file_exists($filename)) {
        return;
    }

    $content = PHP_OS_FAMILY === 'Windows' ? 'extension=php_opentelemetry.dll' : 'extension=opentelemetry';
    file_put_contents($filename, $content);
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
