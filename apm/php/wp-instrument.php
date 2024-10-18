<?php
// Constants
const MIN_PHP_VERSION = '8.0.0';
const PICKLE_URL = 'https://github.com/FriendsOfPHP/pickle/releases/latest/download/pickle.phar';
const APACHE_ENV_FILE = '/etc/apache2/envvars';

function setApacheEnvVariable()
{
    $env_vars = [
        'OTEL_PHP_AUTOLOAD_ENABLED' => getenv('OTEL_PHP_AUTOLOAD_ENABLED') ?: 'true',
        'OTEL_TRACES_EXPORTER' => getenv('OTEL_TRACES_EXPORTER') ?: 'otlp',
        'OTEL_EXPORTER_OTLP_PROTOCOL' => getenv('OTEL_EXPORTER_OTLP_PROTOCOL') ?: 'http/json',
        'OTEL_PROPAGATORS' => getenv('OTEL_PROPAGATORS') ?: 'baggage,tracecontext',
        'OTEL_SERVICE_NAME' => getenv("OTEL_SERVICE_NAME") ?: getenv('MW_SERVICE_NAME') ?: 'service-' . getmypid(),
        'OTEL_EXPORTER_OTLP_ENDPOINT' => getenv("OTEL_EXPORTER_OTLP_ENDPOINT") ?: getenv("MW_TARGET") ?: 'http://localhost:9320'
    ];

    $envVarsContent = "";

    $envVarsContent = implode("\n", array_map(fn($k, $v) => "export $k=\"$v\"", array_keys($env_vars), $env_vars)) . "\n";

    file_put_contents(APACHE_ENV_FILE, $envVarsContent, FILE_APPEND);

    // Step 2: Restart Apache to apply the changes
    exec('service apache2 restart', $output, $resultCode);

    if ($resultCode !== 0) {
        throw new RuntimeException("Failed to restart Apache. Output: " . implode("\n", $output));
    }

    colorLog("Apache restarted successfully with new environment variables.", "i");
}

function command_exists($command_name)
{
    $os_cmd = 'command -v';
    if (PHP_OS_FAMILY === "Windows") {
        $os_cmd = 'where';
    }
    return (null === shell_exec("$os_cmd $command_name")) ? false : true;
}

function execute_command(string $cmd)
{
    colorLog($cmd);
    passthru($cmd, $result_code);
    if ($result_code > 0) {
        throw new RuntimeException("Command failed with exit code {$result_code}");
    }
}

function create_ini_file(string $ini_dir): void
{
    $filename = $ini_dir . DIRECTORY_SEPARATOR . 'opentelemetry.ini';
    if (file_exists($filename)) {
        colorLog("$filename already exists", 'i');
        return;
    }

    $content = PHP_OS_FAMILY === "Windows" ? "extension=php_opentelemetry.dll" : "extension=opentelemetry.so";
    if (file_put_contents($filename, $content) === false) {
        throw new RuntimeException("Error creating $filename");
    }

    colorLog("Created .ini file: $filename", 's');
}

function colorLog(string $message, string $type = 'i'): void
{
    $colors = ['e' => '31', 's' => '32', 'w' => '33', 'i' => '36'];
    $color = $colors[$type] ?? '0';
    echo "\033[{$color}m$message\033[0m\n";
}

function deleteDirectory($dir)
{
    if (!file_exists($dir)) {
        return true;
    }

    if (!is_dir($dir)) {
        return unlink($dir);
    }

    foreach (scandir($dir) as $item) {
        if ($item == '.' || $item == '..') {
            continue;
        }

        if (!deleteDirectory($dir . DIRECTORY_SEPARATOR . $item)) {
            return false;
        }
    }

    return rmdir($dir);
}

function copyOrMoveDirectory(string $source, string $destination, string $mode = 'copy'): void
{
    if (!is_dir($source)) {
        throw new RuntimeException("Source directory doesn't exist: $source");
    }

    if (!is_dir($destination) && !mkdir($destination, 0755, true)) {
        throw new RuntimeException("Failed to create destination directory: $destination");
    }

    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($source, RecursiveDirectoryIterator::SKIP_DOTS),
        RecursiveIteratorIterator::SELF_FIRST
    );

    $sourceLen = strlen($source);
    foreach ($iterator as $item) {
        $target = $destination . substr($item->getPathname(), $sourceLen);
        if ($item->isDir()) {
            if (!is_dir($target) && !mkdir($target)) {
                throw new RuntimeException("Failed to create directory: $target");
            }
        } else {
            if ($mode === 'copy') {
                if (!copy($item->getPathname(), $target)) {
                    throw new RuntimeException("Failed to copy file: {$item->getPathname()}");
                }
            } else {
                if (!rename($item->getPathname(), $target)) {
                    throw new RuntimeException("Failed to move file: {$item->getPathname()}");
                }
            }
        }
    }

    if ($mode === 'move') {
        if (!deleteDirectory($source)) {
            throw new RuntimeException("Failed to remove source directory: $source");
        }
    }
}

function writeStringToFile($filename, $content)
{
    // Check if we can open the file for writing
    $file = fopen($filename, 'w');

    if ($file === false) {
        throw new Exception("Unable to open file: $filename");
    }

    // Write the content to the file
    $bytesWritten = fwrite($file, $content);

    if ($bytesWritten === false) {
        fclose($file);
        throw new Exception("Failed to write to file: $filename");
    }

    // Close the file
    fclose($file);

    return $bytesWritten;
}

function findPhpApacheConfigDir()
{
    // Get PHP version
    $phpVersion = PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;

    // Possible paths
    $possiblePaths = [
        "/etc/php/$phpVersion/apache2/conf.d", // Ubuntu/Debian
        "/etc/php/$phpVersion/apache/conf.d", // Ubuntu alternative
        "/etc/php/apache2/conf.d", // General Debian path
        "/etc/php/apache/conf.d",
        "/etc/php.d", // RedHat/Fedora/CentOS
        "/etc/php/$phpVersion/conf.d",          // Common on some distros
        "/usr/local/etc/php/$phpVersion/conf.d", // macOS Homebrew PHP
        "/etc/apache2/other/php.conf",          // macOS System Apache PHP
        "/usr/local/etc/httpd/extra/",          // macOS Homebrew Apache extra config
    ];

    foreach ($possiblePaths as $path) {
        if (is_dir($path)) {
            return $path;
        }
    }

    // If not found, try to use php -i
    $phpInfo = shell_exec('php -i');
    if ($phpInfo) {
        if (preg_match('/Scan this dir for additional .ini files => (.+)/', $phpInfo, $matches)) {
            $scanDir = trim($matches[1]);
            if (strpos($scanDir, 'apache') !== false || strpos($scanDir, 'conf.d') !== false) {
                return $scanDir;
            }
        }
    }

    return null;
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

// check system requirements
function check_preconditions(): void
{
    if (version_compare(PHP_VERSION, MIN_PHP_VERSION, '<')) {
        throw new RuntimeException("PHP " . MIN_PHP_VERSION . " or higher is required");
    }
    check_extensions();
    ensure_composer();
    if (!command_exists('phpize')) {
        throw new RuntimeException('php-sdk is not installed');
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

function make_executable(string $file): void
{
    if (PHP_OS_FAMILY !== 'Windows') {
        if (!chmod($file, 0755)) {
            throw new RuntimeException("Failed to make $file executable");
        }
    }
}

// downloads and copies otel files to /var/www/otel
function setup()
{
    // install opentelemetry extension
    execute_command("php pickle.phar install opentelemetry -n");

    create_ini_file(trim(shell_exec('php-config --ini-dir')));

    $configDir = findPhpApacheConfigDir();

    if (!$configDir) {
        throw new RuntimeException("Could not determine PHP Apache configuration directory.");
    }

    create_ini_file($configDir);

    $composer = get_composer_command();

    $composerCmd = "$composer init --name \"middleware-labs/wp-auto-instrumentation\" " .
        '--require "open-telemetry/opentelemetry-auto-wordpress:^0.0.15" ' .
        '--require "open-telemetry/sdk:^1.0" ' .
        '--require "open-telemetry/exporter-otlp:^1.0" ' .
        '--require "php-http/guzzle7-adapter:^1.0" --no-interaction';

    execute_command($composerCmd);
    execute_command("$composer install --no-interaction");

    // copy content inside vendor to /var/www/otel/
    copyOrMoveDirectory("vendor", "/var/www/otel", "move");

    // set ini directory
    set_ini($configDir);
}

// set otel.php.in and add prepand autoload code to it.
function set_ini(string $configDir): void
{
    colorLog("PHP Apache configuration directory: $configDir", "i");

    $content = "auto_prepend_file=/var/www/otel/autoload.php";
    file_put_contents("$configDir/mw.wordpress.ini", $content);

    setApacheEnvVariable();
}

try {
    check_preconditions();
    setup();
    colorLog("Setup completed successfully. Please check your Apache configuration.", 's');
} catch (Exception $e) {
    colorLog($e->getMessage(), 'e');
    exit(1);
}
