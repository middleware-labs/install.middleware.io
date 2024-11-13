#!/usr/bin/env php
<?php
define('IS_WINDOWS', strncasecmp(PHP_OS, "WIN", 3) == 0);

// Constants
const MIN_PHP_VERSION = '8.0.0';
const PICKLE_URL = 'https://github.com/FriendsOfPHP/pickle/releases/latest/download/pickle.phar';
const COMPOSER_URL = 'https://getcomposer.org/download/latest-stable/composer.phar';
const APACHE_ENV_FILE = '/etc/apache2/envvars';
const AGENT_CONFIG_PATH = '/etc/mw-agent/agent-config.yaml';

const INI_SCANDIR = 'Scan this dir for additional .ini files';
const INI_MAIN = 'Loaded Configuration File';
const EXTENSION_DIR = 'extension_dir';
const THREAD_SAFETY = 'Thread Safety';
const PHP_VER = 'PHP Version';
const PHP_API = 'PHP API';
const IS_DEBUG = 'Debug Build';

// Project types
const PROJECT_TYPE_LARAVEL = 'laravel';
const PROJECT_TYPE_WORDPRESS = 'wordpress';

// Commands
const CMD_CONFIG_GET = 'config get';
const CMD_CONFIG_SET = 'config set';
const CMD_CONFIG_LIST = 'config list';

// apm installation track statuses
const APM_TRIED = 'apm_tried';
const APM_INSTALLED = 'apm_installed';
const APM_FAILED = 'apm_failed';

$PROJECT_TYPE = detect_project_type();

$LOGS = [];

// Common OpenTelemetry packages
$common_packages = [
    'open-telemetry/sdk:^1.0',
    'open-telemetry/exporter-otlp:^1.0',
    'php-http/guzzle7-adapter:^1.0'
];

// Project-specific packages
$project_packages = [
    PROJECT_TYPE_LARAVEL => [
        'guzzlehttp/guzzle',
        'open-telemetry/api:^1.1',
        'middleware-labs/contrib-auto-laravel',
        'open-telemetry/extension-propagator-b3:^1.1',
        'Middleware/laravel-apm'
    ],
    PROJECT_TYPE_WORDPRESS => [
        'open-telemetry/opentelemetry-auto-wordpress:^0.0.15'
    ]
];

// Main execution
if ($argc < 2) {
    usage($argv[0]);
    exit(1);
}

try {
    match ($argv[1]) {
        'install' => install(),
        'help' => usage($argv[0]),
        default => throw new InvalidArgumentException("Invalid mode"),
    };
} catch (Exception $e) {
    colorLog($e->getMessage(), 'e');
    usage($argv[0]);

    trackEvent(APM_FAILED, 'PostInstall tracking', $PROJECT_TYPE);

    exit(1);
}

function detect_project_type(): string
{
    // Check for Laravel
    if (file_exists('artisan') && file_exists('composer.json')) {
        $composer_json = json_decode(file_get_contents('composer.json'), true);
        if (isset($composer_json['require']['laravel/framework'])) {
            return PROJECT_TYPE_LARAVEL;
        }
    }

    // Check for WordPress
    if (file_exists('wp-config.php') || file_exists('wp-settings.php')) {
        return PROJECT_TYPE_WORDPRESS;
    }

    throw new RuntimeException("Unable to detect project type. Make sure you're in a Laravel or WordPress project root directory.");
}

function getLaravelVersion()
{
    if (file_exists('artisan') && file_exists('composer.json')) {
        $composer_json = json_decode(file_get_contents('composer.json'), true);
        if (isset($composer_json['require']['laravel/framework'])) {
            return $composer_json['require']['laravel/framework'];
        }
    }

    return "";
}

function getWordpressVersion()
{
    $version_file = './wp-includes/version.php';

    if (file_exists($version_file)) {
        $version_content = file_get_contents($version_file);
        if (preg_match('/\$wp_version\s*=\s*\'([^\']+)\'/', $version_content, $matches)) {
            return $matches[1];
        }
    }

    return "";
}

function getLinuxType()
{
    $osReleaseFile = '/etc/os-release';

    if (file_exists($osReleaseFile)) {
        $content = parse_ini_file($osReleaseFile);

        if (isset($content['NAME'])) {
            return $content['NAME'];
        }
    }

    return "Unknown Linux distribution";
}

function install(): void
{
    global $PROJECT_TYPE;

    set_env();
    // $project_type = detect_project_type();
    colorLog("Detected project type: " . strtoupper($PROJECT_TYPE), 's');

    trackEvent(APM_TRIED, 'PreInstall tracking');

    $selectedBinaries = require_binaries_or_exit();
    check_preconditions($selectedBinaries);
    $fl = install_common_components($selectedBinaries);

    // Install project-specific components
    match ($PROJECT_TYPE) {
        PROJECT_TYPE_LARAVEL => install_laravel_specific(),
        PROJECT_TYPE_WORDPRESS => install_wordpress_specific(),
    };

    colorLog("Middleware APM has been successfully installed for " . strtoupper($PROJECT_TYPE), 's');

    trackEvent(APM_INSTALLED, 'PostInstall tracking');
}

function usage(string $script_name): void
{
    colorLog("Usage: $script_name install");
    colorLog("This script will automatically detect if you're in a Laravel or WordPress project and perform the appropriate installation.");
}

function install_common_components($selectedBinaries): bool
{
    // Install Opentelemetry extension
    $flag = install_opentelemetry($selectedBinaries);

    return $flag;
}

function get_project_packages(string $project_type): array
{
    global $common_packages, $project_packages;
    return array_merge($common_packages, $project_packages[$project_type]);
}

function install_laravel_specific(): void
{
    $packages = get_project_packages(PROJECT_TYPE_LARAVEL);
    $composer = get_composer_command();

    // Configure composer
    execute_command("$composer config --no-plugins allow-plugins.php-http/discovery false --no-interaction");
    execute_command("$composer config minimum-stability dev --no-interaction");

    // Install packages
    $require_cmd = "$composer require " . implode(' ', $packages) . " --with-all-dependencies --no-interaction";
    execute_command($require_cmd);
}

function install_wordpress_specific(): void
{
    $packages = get_project_packages(PROJECT_TYPE_WORDPRESS);
    $composer = get_composer_command();

    // Initialize new composer project for WordPress
    $composerCmd = "$composer init --name \"middleware-labs/wp-auto-instrumentation\" " .
        '--no-interaction';
    execute_command($composerCmd);

    // Install packages
    $require_cmd = "$composer require " . implode(' ', $packages) . " --no-interaction";
    execute_command($require_cmd);

    // Set up WordPress-specific configuration
    $configDir = findPhpApacheConfigDir();
    if (!$configDir) {
        throw new RuntimeException("Could not determine PHP Apache configuration directory.");
    }

    // Copy vendor to otel directory
    copyOrMoveDirectory("vendor", "/var/www/otel", "move");

    // Configure WordPress
    configure_wordpress($configDir);
}

function configure_wordpress(string $configDir): void
{
    colorLog("PHP Apache configuration directory: $configDir", "i");

    $content = "auto_prepend_file=/var/www/otel/autoload.php";
    file_put_contents("$configDir/mw.wordpress.ini", $content);

    setApacheEnvVariable();
}

function get_supported_php_versions()
{
    return ['8.0', '8.1', '8.2', '8.3'];
}

function build_known_command_names_matrix()
{
    $results = ['php', 'php-fpm'];

    foreach (get_supported_php_versions() as $phpVersion) {
        list($major, $minor) = explode('.', $phpVersion);
        array_push(
            $results,
            "php{$major}",
            "php{$major}{$minor}",
            "php{$major}.{$minor}",
            "php{$major}-fpm",
            "php{$major}{$minor}-fpm",
            "php{$major}.{$minor}-fpm",
            "php-fpm{$major}",
            "php-fpm{$major}{$minor}",
            "php-fpm{$major}.{$minor}"
        );
    }

    if (IS_WINDOWS) {
        foreach ($results as &$result) {
            $result .= ".exe";
        }
    }

    return array_unique($results);
}

function resolve_command_full_path($command)
{
    if (IS_WINDOWS) {
        if (!strpbrk($command, "/\\")) {
            $path = shell_exec("where " . escapeshellarg($command) . " 2>NUL");
            if ($path === null) {
                // command is not defined
                return false;
            }
            $path = ltrim($path, "\r\n");
        } elseif (!file_exists($command)) {
            return false;
        } else {
            $path = $command;
        }
    } else {
        $path = exec("command -v " . escapeshellarg($command));
        if (empty($path)) {
            // command is not defined
            return false;
        }
    }

    // Resolving symlinks
    return realpath($path);
}

function search_php_binaries($prefix = '')
{
    colorLog("Searching for available php binaries, this operation might take a while.");

    $resolvedPaths = [];

    $allPossibleCommands = build_known_command_names_matrix();

    // First, we search in $PATH, for php, php8, php83, php8.3, php8.3-fpm, etc....
    foreach ($allPossibleCommands as $command) {
        if ($resolvedPath = resolve_command_full_path($command)) {
            $resolvedPaths[$command] = $resolvedPath;
        }
    }

    // Then we search in known possible locations for popular installable paths on different systems.
    $pathsFound = [];
    if (IS_WINDOWS) {
        $bootDisk = realpath('/');

        $standardPaths = [
            dirname(PHP_BINARY),
            PHP_BINDIR,
            $bootDisk . 'WINDOWS',
        ];

        foreach (scandir($bootDisk) as $file) {
            if (stripos($file, "php") !== false) {
                $standardPaths[] = "$bootDisk$file";
            }
        }

        $chocolateyDir = getenv("ChocolateyToolsLocation") ?: $bootDisk . 'tools'; // chocolatey tools location
        if (is_dir($chocolateyDir)) {
            foreach (scandir($chocolateyDir) as $file) {
                if (stripos($file, "php") !== false) {
                    $standardPaths[] = "$chocolateyDir/$file";
                }
            }
        }

        // Windows paths are case-insensitive
        $standardPaths = array_intersect_key(array_map('strtolower', $standardPaths), array_unique($standardPaths));

        foreach ($standardPaths as $standardPath) {
            foreach ($allPossibleCommands as $command) {
                $resolvedPath = $standardPath . '\\' . $command;
                if (file_exists($resolvedPath)) {
                    $pathsFound[] = $resolvedPath;
                }
            }
        }
    } else {
        $standardPaths = [
            $prefix . '/usr/bin',
            $prefix . '/usr/sbin',
            $prefix . '/usr/local/bin',
            $prefix . '/usr/local/sbin',
        ];

        $remiSafePaths = array_map(function ($phpVersion) use ($prefix) {
            list($major, $minor) = explode('.', $phpVersion);
            /* php is installed to /usr/bin/php{$major}{$minor} so we do not need to do anything special, while php-fpm
             * is installed to /opt/remi/php{$major}{$minor}/root/usr/sbin and it needs to be added to the searched
             * locations.
             */
            return "{$prefix}/opt/remi/php{$major}{$minor}/root/usr/sbin";
        }, get_supported_php_versions());

        $pleskPaths = array_map(function ($phpVersion) use ($prefix) {
            return "/opt/plesk/php/$phpVersion/bin";
        }, get_supported_php_versions());

        $escapedSearchLocations = implode(
            ' ',
            array_map('escapeshellarg', array_merge($standardPaths, $remiSafePaths, $pleskPaths))
        );
        $escapedCommandNamesForFind = implode(
            ' -o ',
            array_map(
                function ($cmd) {
                    return '-name ' . escapeshellarg($cmd);
                },
                $allPossibleCommands
            )
        );

        exec(
            "find -L $escapedSearchLocations -type f \( $escapedCommandNamesForFind \) 2>/dev/null",
            $pathsFound
        );
    }

    foreach ($pathsFound as $path) {
        $resolved = realpath($path);
        if (in_array($resolved, $resolvedPaths)) {
            continue;
        }
        $resolvedPaths[$path] = $resolved;
    }

    $results = [];
    foreach ($resolvedPaths as $command => $realpath) {
        $hasShebang = file_get_contents($realpath, false, null, 0, 2) === "#!";
        $results[$command] = [
            "shebang" => $hasShebang,
            "path" => $realpath,
        ];
    }

    return $results;
}

function require_binaries_or_exit()
{
    $selectedBinaries = [];

    foreach (search_php_binaries() as $command => $binaryinfo) {
        if (!$binaryinfo["shebang"]) {
            $selectedBinaries[$command] = $binaryinfo["path"];
        }
    }

    if (empty($selectedBinaries)) {
        throw new RuntimeException("At least one binary must be specified\n");
    }

    return $selectedBinaries;
}

function ini_values($binary)
{
    $properties = [PHP_VER, INI_MAIN, INI_SCANDIR, EXTENSION_DIR, THREAD_SAFETY, PHP_API, IS_DEBUG];
    $lines = [];
    // Timezone is irrelevant to this script. Quick-and-dirty workaround to the PHP 5 warning with missing timezone
    exec(escapeshellarg($binary) . " -d date.timezone=UTC -i", $lines);
    $found = [];
    foreach ($lines as $line) {
        $parts = explode('=>', $line);
        if (count($parts) === 2 || count($parts) === 3) {
            $key = trim($parts[0]);
            if (in_array($key, $properties)) {
                $value = trim(count($parts) === 2 ? $parts[1] : $parts[2]);

                if ($value === "(none)") {
                    continue;
                }

                $found[$key] = $value;
            }
        }
    }

    if ($found[EXTENSION_DIR] == "") {
        $found[EXTENSION_DIR] = dirname(PHP_BINARY);
    } elseif ($found[EXTENSION_DIR][0] != "/" && (!IS_WINDOWS || !preg_match('~^([A-Z]:[\\\\/]|\\\\{2})~i', $found[EXTENSION_DIR]))) {
        $found[EXTENSION_DIR] = dirname(PHP_BINARY) . '/' . $found[EXTENSION_DIR];
    }

    return $found;
}

function is_opentelemetry_installed($binary): bool
{
    $modules = explode("\n", shell_exec("$binary -m") ?: '');
    return in_array('opentelemetry', $modules);
}

function install_opentelemetry($selectedBinaries)
{
    $flag = true;

    foreach ($selectedBinaries as $command => $fullPath) {
        $binaryForLog = ($command === $fullPath) ? $fullPath : "$command ($fullPath)";

        if (!is_opentelemetry_installed($fullPath)) {
            colorLog("Installing Opentelemetry Extension to Binary: $binaryForLog");

            execute_command("$fullPath pickle.phar install opentelemetry -n");

            $phpProperties = ini_values($fullPath);
            if (!isset($phpProperties[INI_SCANDIR])) {
                if (!isset($phpProperties[INI_MAIN])) {
                    if (IS_WINDOWS) {
                        $phpProperties[INI_MAIN] = dirname($fullPath) . "/php.ini";
                    } else {
                        throw new RuntimeException(
                            "It is not possible to perform installation on this "
                                . "system because there is no scan directory and no "
                                . "configuration file loaded."
                        );
                    }
                }

                colorLog(
                    "Performing an installation without a scan directory may "
                        . "result in fragile installations that are broken by normal "
                        . "system upgrades. It is advisable to use the configure "
                        . "switch --with-config-file-scan-dir when building PHP.",
                    "w"
                );
            }

            $iniFiles = get_ini_files($phpProperties);

            $content = IS_WINDOWS ? 'extension=php_opentelemetry.dll' : 'extension=opentelemetry.so';

            foreach ($iniFiles as $filename) {
                if (file_put_contents($filename, $content, FILE_APPEND) === false) {
                    throw new RuntimeException("Failed to write to INI file: $filename");
                }
            }

            if (check_postconditions($fullPath)) {
                colorLog("Opentelemetry Extension Installation to '$binaryForLog' was successful\n");
            } else {
                $flag = false;
            }
        }
    }

    return $flag;
}

function get_ini_files(array $phpProperties)
{
    $ini_files = [];

    $ini_dir = $phpProperties[INI_SCANDIR];

    if (!isset($ini_dir)) {
        array_push($ini_files, $phpProperties[INI_MAIN]);
        return $ini_files;
    }

    array_push($ini_files, $ini_dir . DIRECTORY_SEPARATOR . 'opentelemetry.ini');

    if (strpos($ini_dir, '/cli/conf.d') !== false) {
        $apacheConfd = str_replace('/cli/conf.d', '/apache2/conf.d', $ini_dir);
        $apacheIni =  $apacheConfd . DIRECTORY_SEPARATOR . 'opentelemetry.ini';
        if (file_exists($apacheConfd) && !file_exists($apacheIni)) {
            array_push($ini_files, $apacheIni);
        }

        $fpmConfd = str_replace('/cli/conf.d', '/fpm/conf.d', $ini_dir);
        if (file_exists(($fpmConfd))) {
            array_push($ini_files, $fpmConfd . DIRECTORY_SEPARATOR . 'opentelemetry.ini');
        }
    }

    return $ini_files;
}

function check_postconditions($binary): bool
{
    $extension_file = IS_WINDOWS ? '\php_opentelemetry.dll' : '/opentelemetry.so';
    $php_info = array();
    $res_code = null;

    exec("$binary -i", $php_info, $res_code);

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

    if (!in_array('opentelemetry', explode("\n", shell_exec("$binary -m")))) {
        colorLog("ERROR: opentelemetry extension has not been added to ini file", 'e');
        return false;
    }

    return true;
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
        $out = shell_exec('httpd -k restart');
        throw new RuntimeException("Failed to restart Apache. Output: " . implode("\n", $output));
    }

    colorLog("Apache restarted successfully with new environment variables.", "i");
}


function set_env(): void
{
    $env_vars = [
        'OTEL_PHP_AUTOLOAD_ENABLED' => getenv('OTEL_PHP_AUTOLOAD_ENABLED') ?: 'true',
        'OTEL_TRACES_EXPORTER' => getenv('OTEL_TRACES_EXPORTER') ?: 'otlp',
        'OTEL_EXPORTER_OTLP_PROTOCOL' => getenv('OTEL_EXPORTER_OTLP_PROTOCOL') ?: 'http/json',
        'OTEL_PROPAGATORS' => getenv('OTEL_PROPAGATORS') ?: 'baggage,tracecontext,b3multi',
        'OTEL_SERVICE_NAME' => getenv("OTEL_SERVICE_NAME") ?: getenv('MW_SERVICE_NAME') ?: 'service-' . getmypid(),
        'OTEL_EXPORTER_OTLP_ENDPOINT' => getenv("OTEL_EXPORTER_OTLP_ENDPOINT") ?: getenv("MW_TARGET") ?: 'http://localhost:9320',
        'COMPOSER_ALLOW_SUPERUSER' => 1
    ];

    foreach ($env_vars as $key => $value) {
        if (empty(getenv($key))) {
            putenv("$key=$value");
        }
    }
}

function check_extensions($binary)
{
    $flag = false;

    $installed_extensions = shell_exec(escapeshellarg($binary) . " -m");

    $extensions = [
        'zlib',
        'mbstring',
        'simplexml',
        'json',
        'dom',
        'openssl',
        'Phar',
        'fileinfo',
        'pcre',
        'xmlwriter',
        'gd'
    ];

    colorLog("Checking PHP extensions for $binary...");

    foreach ($extensions as $extName) {
        if (!in_array($extName, array_map("trim", explode("\n", $installed_extensions)))) {
            colorLog("$extName: Not installed in $binary", "w");
            $flag = true;
        }
    }

    if ($flag) {
        colorLog("Please install the above mentioned extensions first. Continuing without them might lead to unexpected behavior and errors.", "w");
    } else {
        colorLog("All required extensions are installed for $binary");
    }
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

function check_preconditions($selectedBinaries): void
{
    foreach ($selectedBinaries as $k => $v) {
        check_extensions($v);
    }

    ensure_composer();

    if (!command_exists('phpize')) {
        throw new RuntimeException('php-sdk (php-dev) is not installed');
    }

    download_file(PICKLE_URL, 'pickle.phar');
    make_executable('pickle.phar');
}

function colorLog(string $message, string $type = 'i'): void
{
    global $LOGS;

    $colors = ['e' => '31', 's' => '32', 'w' => '33', 'i' => '36'];
    $labels = ['e' => '[ERROR]', 's' => '[SUCCESS]', 'w' => '[WARN]', 'i' => '[INFO]'];

    $timestamp = date('Y-m-d H:i:s');
    $color = $colors[$type] ?? '0';
    $label = $labels[$type] ?? '[LOG]';

    $log = "[$timestamp] $label $message\n";

    // store logs
    array_push($LOGS, $log);

    echo "\033[{$color}m$log\033[0m\n";
}

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

function execute_command(string $cmd): void
{
    colorLog($cmd);
    $output = null;
    $result_code = null;
    exec($cmd, $output, $result_code);
    // passthru($cmd, $result_code);
    if ($result_code > 0) {
        $out = "";
        foreach ($output as $line) {
            $out += "$line\n";
        }
        colorLog($out, 'e');
        throw new RuntimeException("Command failed with exit code {$result_code}");
    }
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

function read_agent_config($config_path)
{
    try {
        if (file_exists($config_path)) {
            $file_content = file_get_contents($config_path);
            if ($file_content === false) {
                colorLog("APM Tracking: Unable to read config file", "e");
                return null;
            }

            $lines = explode("\n", $file_content);
            $api_key = "";
            $target = "";

            foreach ($lines as $line) {
                // Skip comments and empty lines
                $line = trim($line);
                if (empty($line) || strpos($line, '#') === 0) {
                    continue;
                }

                // Look for api-key
                if (strpos($line, 'api-key:') !== false) {
                    $api_key = trim(explode('api-key:', $line)[1]);
                }

                // Look for target
                if (strpos($line, 'target:') !== false) {
                    $target = trim(explode('target:', $line)[1]);
                }
            }


            return [
                'api_key' => $api_key,
                'target' => $target
            ];
        } else {
            colorLog("APM Tracking: Config file not found", "e");
        }
    } catch (Exception $e) {
        colorLog("APM Tracking: Error reading config file: " . $e->getMessage(), "e");
    }

    return null;
}

function makeRequest($url, $data, $timeout = 5)
{
    $ch = curl_init();

    curl_setopt_array($ch, [
        CURLOPT_URL => $url,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => $data,
        CURLOPT_TIMEOUT => $timeout,
        CURLOPT_SSL_VERIFYPEER => false,
        CURLOPT_SSL_VERIFYHOST => false,
        CURLOPT_HTTPHEADER => [
            'Content-Type: application/json',
            'Content-Length: ' . strlen($data)
        ]
    ]);

    try {
        $response = curl_exec($ch);
        if ($response === false) {
            colorLog('Warning: Request failed - ' . curl_error($ch), 'e');
        } else {
            colorLog("Successfully tracked event");
        }
    } catch (Exception $e) {
        colorLog('Warning: Request failed - ' . $e->getMessage(), 'e');
    } finally {
        curl_close($ch);
    }
}

function trackEvent($status = APM_TRIED, $reason = 'PreInstall tracking')
{
    global $PROJECT_TYPE, $LOGS;

    $config = read_agent_config(AGENT_CONFIG_PATH);
    $config['project_type'] = $PROJECT_TYPE;

    if (empty($config) || empty($config['api_key']) || empty($config['target'])) {
        colorLog("Invalid configuration: Missing API key or URL", "e");
        return;
    }

    $payload = [
        'status' => $status,
        'metadata' => [
            'host_id' => gethostname(),
            'os_type' => PHP_OS,
            'apm_type' => "PHP",
            'apm_data' => [
                'service_name' => getenv('OTEL_SERVICE_NAME'),
                'script' => 'php-install',
                'os_version' => php_uname('r'),
                'php_version' => PHP_VERSION,
                'reason' => $reason,
                'framework_type' => $config['project_type'],
                'linux_distro' => getLinuxType(),
            ]
        ]
    ];

    if ($reason === 'PostInstall tracking') {
        $payload["metadata"]["message"] = $LOGS;
    }

    $version = '';

    if ($config['project_type'] === PROJECT_TYPE_LARAVEL) {
        $version = getLaravelVersion();
    } else if ($config['project_type'] === PROJECT_TYPE_WORDPRESS) {
        $version = getWordpressVersion();
    }

    $payload['apm_data']['framework_version'] = $version;

    $data = json_encode($payload);

    // Build the URL
    $baseUrl = rtrim($config['target'], '/');
    $pathSuffix = 'api/v1/apm/tracking/' . $config['api_key'];
    $url = $baseUrl . '/' . $pathSuffix;

    makeRequest($url, $data);
}
