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
const PROJECT_TYPE_GENERIC = 'generic';

// APM types
const APM_TYPE_OTEL = 'opentelemetry';
const APM_TYPE_DATADOG = 'datadog';

// Commands
const CMD_CONFIG_GET = 'config get';
const CMD_CONFIG_SET = 'config set';
const CMD_CONFIG_LIST = 'config list';

// apm installation track statuses
const APM_TRIED = 'apm_tried';
const APM_INSTALLED = 'apm_installed';
const APM_FAILED = 'apm_failed';

// command line options
const ADD_INI_DIRS = 'additional-ini-dir';
const APM_TYPE = 'apm-type';

// 
const BASE_DIR = '/opt/middleware/apm/php';

// globals variables for configuration
$PROJECT_TYPE;
$APM_TYPE;
$LOGS = [];
$ARGS = [];

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
  parseCliArgs();

  switch ($argv[1]) {
    case 'install':
      install();
      break;
    case 'uninstall':
      uninstall();
      break;
    case 'help':
      usage($argv[0]);
      break;
    default:
      throw new InvalidArgumentException("Invalid mode");
  }
} catch (Exception $e) {
  colorLog($e->getMessage(), 'e');
  usage($argv[0]);

  trackEvent(APM_FAILED, 'PostInstall tracking');

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

  // Return generic type if no specific framework is detected
  return PROJECT_TYPE_GENERIC;
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

function parseCliArgs()
{
  global $ARGS, $APM_TYPE;

  // Debug: Print all command line arguments
  $args = $_SERVER['argv'];
  colorLog("Command line arguments: " . implode(", ", $args), 'i');

  // Default to OpenTelemetry
  $APM_TYPE = APM_TYPE_OTEL;

  // Manual parsing
  for ($i = 1; $i < count($args); $i++) {
    $arg = $args[$i];

    // Parse --apm-type
    if (strpos($arg, '--apm-type=') === 0) {
      $type = substr($arg, strlen('--apm-type='));
      $type = strtolower($type);
      colorLog("Found APM type in argument: $type", 'i');
      if ($type === APM_TYPE_OTEL || $type === APM_TYPE_DATADOG) {
        $APM_TYPE = $type;
        colorLog("Setting APM type to: $type", 's');
      }
    } else if ($arg === '--apm-type' && isset($args[$i + 1])) {
      $type = strtolower($args[++$i]);
      colorLog("Found APM type in next argument: $type", 'i');
      if ($type === APM_TYPE_OTEL || $type === APM_TYPE_DATADOG) {
        $APM_TYPE = $type;
        colorLog("Setting APM type to: $type", 's');
      }
    }

    // Parse --additional-ini-dir
    if (strpos($arg, '--additional-ini-dir=') === 0) {
      $val = substr($arg, strlen('--additional-ini-dir='));
      $ARGS[ADD_INI_DIRS] = array_map('trim', explode(',', $val));
    } else if ($arg === '--additional-ini-dir' && isset($args[$i + 1])) {
      $val = $args[++$i];
      $ARGS[ADD_INI_DIRS] = array_map('trim', explode(',', $val));
    }
  }

  // Validate
  if (isset($ARGS[ADD_INI_DIRS]) && count($ARGS[ADD_INI_DIRS]) < 1) {
    throw new RuntimeException("Please provide config directory (.ini dir) path for apache");
  }
}

function install(): void
{
  global $PROJECT_TYPE, $APM_TYPE;
  $PROJECT_TYPE = detect_project_type();
  colorLog("Detected project type: " . strtoupper($PROJECT_TYPE), 's');
  colorLog("Using APM type: " . strtoupper($APM_TYPE), 's');

  trackEvent(APM_TRIED, 'PreInstall tracking');

  $selectedBinaries = require_binaries_or_exit();
  check_preconditions($selectedBinaries);
  if ($APM_TYPE === APM_TYPE_OTEL) {
    if (version_compare(PHP_VERSION, MIN_PHP_VERSION, '<')) {
      colorLog("PHP " . MIN_PHP_VERSION . " or higher is required for opentelemetry based installation", 'w');
    } else {
      install_opentelemetry_apm($selectedBinaries);
    }
  } else {
    install_datadog_apm($selectedBinaries);
  }

  colorLog("APM has been successfully installed for " . strtoupper($PROJECT_TYPE), 's');

  trackEvent(APM_INSTALLED, 'PostInstall tracking');
}

/**
 * Main uninstall function that decides which APM to uninstall
 * @param array $options Command line options
 * @return bool Success status
 */
function uninstall()
{
  global $PROJECT_TYPE, $APM_TYPE;
  $PROJECT_TYPE = detect_project_type();
  colorLog("Detected project type: " . strtoupper($PROJECT_TYPE), 's');
  colorLog("Uninstalling APM type: " . strtoupper($APM_TYPE), 's');

  $selectedBinaries = require_binaries_or_exit();

  if ($APM_TYPE === APM_TYPE_OTEL) {
    return uninstall_opentelemetry_apm($selectedBinaries);
  } else {
    return uninstall_datadog_apm($selectedBinaries);
  }
}

function install_opentelemetry_apm($selectedBinaries): void
{
  global $PROJECT_TYPE;

  // Install OpenTelemetry extension
  $fl = install_opentelemetry_extension($selectedBinaries);

  // Install project-specific components
  switch ($PROJECT_TYPE) {
    case PROJECT_TYPE_LARAVEL:
      install_laravel_specific();
      break;
    case PROJECT_TYPE_WORDPRESS:
      install_wordpress_specific($selectedBinaries);
      break;
    case PROJECT_TYPE_GENERIC:
      colorLog("framework-specific setup needed for generic PHP project with OpenTelemetry", 'i');
      break;
  }

  // Set environment variables for OpenTelemetry
  try {
    setOpenTelemetryEnvVariables();
  } catch (\Throwable $th) {
    colorLog("Please set OpenTelemetry environment variables and restart your server. (See docs for more info)", "w");
    $envVars = [
      'OTEL_PHP_AUTOLOAD_ENABLED="true"',
      'OTEL_TRACES_EXPORTER="otlp"',
      'OTEL_EXPORTER_OTLP_PROTOCOL="http/json"',
      'OTEL_PROPAGATORS="baggage,tracecontext"',
      'OTEL_SERVICE_NAME="your-service-name"',
      'OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:9320"'
    ];
    colorLog("Required environment variables:", "i");
    foreach ($envVars as $var) {
      colorLog("export $var", "i");
    }
  }
}

function install_datadog_apm($selectedBinaries): void
{
  // Install Datadog tracer
  install_datadog_tracer($selectedBinaries);

  // Datadog doesn't need framework-specific setup
  // colorLog("Datadog tracer works with any PHP application without framework-specific configuration", 'i');

  // Set environment variables for Datadog
  try {
    setDatadogEnvVariables();
  } catch (\Throwable $th) {
    colorLog("Please set Datadog environment variables and restart your server. (See docs for more info)", "w");
    $envVars = [
      'DD_SERVICE="your-service-name"',
      'DD_TRACE_AGENT_URL="http://localhost:8126"',
      'DD_TRACE_DEBUG="0"'
    ];
    colorLog("Required environment variables:", "i");
    foreach ($envVars as $var) {
      colorLog("export $var", "i");
    }
  }
}

function usage(string $script_name): void
{
  echo "Usage: php $script_name <command> [options]\n\n";
  echo "Commands:\n";
  echo "  install    Install the application\n";
  echo "  help       Show this help message\n\n";
  echo "Options:\n";
  echo "  --additional-ini-dir    Comma-separated list of additional INI directories (Required for install)\n";
  echo "  --apm-type             APM type to install: 'opentelemetry' or 'datadog' (Default: opentelemetry)\n\n";
  echo "Example:\n";
  echo "  php $script_name install --additional-ini-dir=/path1,/path2 --web-root=/var/www --apm-type=datadog\n";
  echo "\nThis script will automatically detect if you're in a Laravel or WordPress project and perform the appropriate installation.\n";
}

function install_opentelemetry_extension($selectedBinaries): bool
{
  $flag = true;

  foreach ($selectedBinaries as $command => $fullPath) {
    $binaryForLog = ($command === $fullPath) ? $fullPath : "$command ($fullPath)";

    if (!is_extension_installed($fullPath, 'opentelemetry')) {
      colorLog("Installing OpenTelemetry Extension to Binary: $binaryForLog");

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
        if (file_put_contents($filename, "\n" . $content . "\n", FILE_APPEND) === false) {
          throw new RuntimeException("Failed to write to INI file: $filename");
        }
      }

      if (check_extension_installed($fullPath, 'opentelemetry')) {
        colorLog("OpenTelemetry Extension Installation to '$binaryForLog' was successful\n");
      } else {
        $flag = false;
      }
    } else {
      colorLog("OpenTelemetry Extension already installed on '$binaryForLog'\n");
    }
  }

  return $flag;
}

function install_datadog_tracer($selectedBinaries): bool
{
  $architecture = get_architecture();
  $platform = "$architecture-" . (IS_WINDOWS ? "windows" : "linux-" . (is_alpine() ? 'musl' : 'gnu'));

  // Create temporary directory for Datadog files
  $tmpDir = sys_get_temp_dir() . '/dd-install';
  if (!file_exists($tmpDir)) {
    execute_command("mkdir " . (IS_WINDOWS ? "" : "-p ") . escapeshellarg($tmpDir));
  }

  // Download Datadog tracer package
  $version = "1.8.2"; // Use the latest stable version

  // Similar to datadog-setup.php approach, try with a suffix for PHP version specifics
  $phpProperties = ini_values($selectedBinaries[array_key_first($selectedBinaries)]);
  $extensionSuffix = '';
  if (isset($phpProperties[IS_DEBUG]) && is_truthy($phpProperties[IS_DEBUG])) {
    $extensionSuffix .= '-debug';
  }
  if (isset($phpProperties[THREAD_SAFETY]) && is_truthy($phpProperties[THREAD_SAFETY])) {
    $extensionSuffix .= '-zts';
  }

  $extensionVersion = $phpProperties[PHP_API] ?? '';
  $tar_gz_suffix = $extensionVersion ? "-$extensionVersion$extensionSuffix" : "";

  // Additional date suffix for Linux builds
  $dateSuffix = IS_WINDOWS ? "" : "-20230831"; // Hardcoded known date

  // Try downloading with version-specific suffix first
  $baseUrl = "https://github.com/DataDog/dd-trace-php/releases/download/$version/dd-library-php-$version-$platform";
  $attempts = [
    // First attempt: with both suffixes (for Linux)
    $baseUrl . $tar_gz_suffix . $dateSuffix . ".tar.gz",
    // Second attempt: with just PHP API version suffix
    $baseUrl . $tar_gz_suffix . ".tar.gz",
    // Third attempt: with just date suffix (for Linux)
    $baseUrl . $dateSuffix . ".tar.gz",
    // Last attempt: base URL without any suffix
    $baseUrl . ".tar.gz"
  ];

  $url = "";
  $success = false;

  // If we're on Windows, skip Linux-specific attempts
  $attemptsToTry = IS_WINDOWS ? array_filter($attempts, function ($url) {
    return strpos($url, "-20230831") === false;
  }) : $attempts;

  foreach ($attemptsToTry as $attemptUrl) {
    colorLog("Trying to download from: $attemptUrl", 'i');

    // Create a stream context that times out quickly for checking URL existence
    $context = stream_context_create([
      'http' => [
        'method' => 'HEAD',
        'timeout' => 2
      ]
    ]);

    // Check if the URL exists
    $headers = @get_headers($attemptUrl, 1, $context);
    if ($headers && strpos($headers[0], '200') !== false) {
      $url = $attemptUrl;
      colorLog("Found valid URL: $url", 's');
      $success = true;
      break;
    }
  }

  // If all attempts fail, try a brute force approach with different date patterns
  if (!$success && !IS_WINDOWS) {
    $possibleDates = ['20230831', '20231031', '20240131', '20240331', '20240630', date('Ymd')];

    foreach ($possibleDates as $date) {
      $testUrl = $baseUrl . "-$date.tar.gz";
      colorLog("Testing date pattern URL: $testUrl", 'i');

      $headers = @get_headers($testUrl, 1, $context);
      if ($headers && strpos($headers[0], '200') !== false) {
        $url = $testUrl;
        colorLog("Found valid URL with date pattern: $url", 's');
        $success = true;
        break;
      }
    }
  }

  // If we still haven't found a valid URL, use the hardcoded one as last resort
  if (!$success) {
    if (IS_WINDOWS) {
      $url = $baseUrl . ".tar.gz";
    } else {
      $url = $baseUrl . "-20230831.tar.gz";
    }
    colorLog("Using fallback URL: $url", 'w');
  }

  $tmpDirTarGz = "$tmpDir/dd-library-php-$platform.tar.gz";

  colorLog("Downloading Datadog tracer from $url");
  try {
    download_file($url, $tmpDirTarGz);
  } catch (RuntimeException $e) {
    colorLog("Failed to download Datadog tracer package: " . $e->getMessage(), 'e');
    return false;
  }

  // Extract archive
  execute_command("tar -xf " . escapeshellarg($tmpDirTarGz) . " -C " . escapeshellarg($tmpDir));

  // List available extensions in the downloaded package
  $availableExtDirs = [];
  $extensionDir = "$tmpDir/dd-library-php/trace/ext";
  if (is_dir($extensionDir)) {
    $availableExtDirs = glob("$extensionDir/*");
    $availableExtDirs = array_map('basename', $availableExtDirs);
    colorLog("Available PHP API versions in package: " . implode(", ", $availableExtDirs), 'i');
  }

  $flag = true;
  foreach ($selectedBinaries as $command => $fullPath) {
    $binaryForLog = ($command === $fullPath) ? $fullPath : "$command ($fullPath)";
    colorLog("Installing Datadog tracer to binary: $binaryForLog");

    $phpProperties = ini_values($fullPath);

    // Output PHP properties for debugging
    colorLog("PHP Properties for $binaryForLog:", 'i');
    colorLog("Extension dir: " . ($phpProperties[EXTENSION_DIR] ?? 'not detected'), 'i');
    colorLog("PHP API version: " . ($phpProperties[PHP_API] ?? 'not detected'), 'i');

    // Determine extension suffix based on PHP properties
    $extensionSuffix = '';
    if (isset($phpProperties[IS_DEBUG]) && is_truthy($phpProperties[IS_DEBUG])) {
      $extensionSuffix .= '-debug';
    }
    if (isset($phpProperties[THREAD_SAFETY]) && is_truthy($phpProperties[THREAD_SAFETY])) {
      $extensionSuffix .= '-zts';
    }

    // Get extension directory and version
    $extensionDir = $phpProperties[EXTENSION_DIR] ?? '/usr/lib/php';
    $extensionVersion = $phpProperties[PHP_API] ?? '';

    if (empty($extensionVersion)) {
      colorLog("Could not detect PHP API version for $binaryForLog", 'e');
      $flag = false;
      continue;
    }

    // Path to the extension file in the extracted archive
    $extensionPrefix = IS_WINDOWS ? "php_" : "";
    $extensionSuffixFile = IS_WINDOWS ? "dll" : "so";
    $extensionRealPath = "$tmpDir/dd-library-php/trace/ext/$extensionVersion/"
      . $extensionPrefix . "ddtrace$extensionSuffix." . $extensionSuffixFile;

    colorLog("Looking for extension at: $extensionRealPath", 'i');

    if (!file_exists($extensionRealPath)) {
      // Try variants of extension suffix if the exact one doesn't exist
      $alternativeSuffixes = ['', '-zts', '-debug', '-zts-debug'];
      $found = false;

      foreach ($alternativeSuffixes as $altSuffix) {
        $altPath = "$tmpDir/dd-library-php/trace/ext/$extensionVersion/"
          . $extensionPrefix . "ddtrace$altSuffix." . $extensionSuffixFile;

        if (file_exists($altPath)) {
          colorLog("Found alternative extension at: $altPath", 'i');
          $extensionRealPath = $altPath;
          $found = true;
          break;
        }
      }

      // Try other available API versions if the exact API version does not exist
      if (!$found && count($availableExtDirs) > 0) {
        colorLog("Extension not found for PHP API version $extensionVersion, trying other versions", 'w');

        // Sort available API versions by newest first (assuming higher numbers are newer)
        usort($availableExtDirs, function ($a, $b) {
          return version_compare($b, $a);
        });

        foreach ($availableExtDirs as $alternativeVersion) {
          // Skip non-numeric directories
          if (!is_numeric($alternativeVersion))
            continue;

          foreach ($alternativeSuffixes as $altSuffix) {
            $altPath = "$tmpDir/dd-library-php/trace/ext/$alternativeVersion/"
              . $extensionPrefix . "ddtrace$altSuffix." . $extensionSuffixFile;

            if (file_exists($altPath)) {
              colorLog("Found compatible extension with API version $alternativeVersion", 'i');
              $extensionRealPath = $altPath;
              $found = true;
              break 2;
            }
          }
        }
      }

      if (!$found) {
        colorLog("Datadog extension not available for this PHP version", 'e');
        $flag = false;
        continue;
      }
    }

    // Copy extension to extension directory
    $extensionDestination = $extensionDir . '/' . $extensionPrefix . 'ddtrace.' . $extensionSuffixFile;
    safe_copy_extension($extensionRealPath, $extensionDestination);

    // Get ini files to update
    $iniFiles = get_ini_files($phpProperties, 'ddtrace');

    // Add extension to ini files
    $content = IS_WINDOWS ? 'extension=ddtrace' : 'extension=ddtrace.so';
    foreach ($iniFiles as $iniFilePath) {
      if (file_put_contents($iniFilePath, "\n" . $content . "\n", FILE_APPEND) === false) {
        colorLog("Failed to write to INI file: $iniFilePath", 'e');
        $flag = false;
        continue;
      }
      colorLog("Updated INI file: $iniFilePath");
    }

    if (check_extension_installed($fullPath, 'ddtrace')) {
      colorLog("Datadog tracer installation to '$binaryForLog' was successful\n");
    } else {
      colorLog("Failed to install Datadog tracer to '$binaryForLog'\n", 'e');
      $flag = false;
    }
  }

  // Create directory structure for source files
  $installDir = '/opt/datadog/dd-library/1.8.2';
  $sourceDir = $installDir . '/dd-trace-sources/src';

  // Create the directories if they don't exist
  if (!is_dir($installDir)) {
    execute_command("mkdir -p " . escapeshellarg($installDir));
    colorLog("Created installation directory: $installDir", 's');
  }

  if (!is_dir($sourceDir)) {
    execute_command("mkdir -p " . escapeshellarg($sourceDir));
    colorLog("Created source directory: $sourceDir", 's');
  }

  // Extract source files from the archive to the source directory
  $tmpSrcDir = "$tmpDir/dd-library-php/trace/src";
  if (is_dir($tmpSrcDir)) {
    execute_command("cp -r " . escapeshellarg($tmpSrcDir) . "/* " . escapeshellarg($sourceDir));
    colorLog("Copied tracer source files to: $sourceDir", 's');
  } else {
    colorLog("Warning: Source directory not found in the downloaded package", 'w');
  }

  // Update INI files to include the sources_path
  foreach ($selectedBinaries as $command => $fullPath) {
    $binaryForLog = ($command === $fullPath) ? $fullPath : "$command ($fullPath)";
    $phpProperties = ini_values($fullPath);

    // Get INI files
    $iniFiles = get_ini_files($phpProperties, 'ddtrace');

    // For Apache, try to detect PHP configuration directory
    if (strpos($command, 'apache') !== false || strpos($binaryForLog, 'apache') !== false) {
      // Common Apache PHP configuration directories
      $apacheDirs = [
        '/etc/php/*/apache2/conf.d',
        '/etc/php-apache/conf.d',
        '/etc/php.d/apache',
        '/etc/php-*/conf.d/apache'
      ];

      foreach ($apacheDirs as $pattern) {
        $dirs = glob($pattern, GLOB_ONLYDIR);
        if (!empty($dirs)) {
          foreach ($dirs as $dir) {
            $apacheIni = $dir . '/ddtrace.ini';
            if (!in_array($apacheIni, $iniFiles)) {
              $iniFiles[] = $apacheIni;
              colorLog("Added Apache PHP configuration: $apacheIni", 's');
            }
          }
        }
      }
    }

    // Also check for specific Apache configuration in INI scan dir
    if (isset($phpProperties[INI_SCANDIR])) {
      $scanDir = $phpProperties[INI_SCANDIR];

      // Check for Apache-specific config directories
      if (strpos($scanDir, '/cli/conf.d') !== false) {
        $apacheConfd = str_replace('/cli/conf.d', '/apache2/conf.d', $scanDir);
        if (is_dir($apacheConfd)) {
          $apacheIni = $apacheConfd . '/ddtrace.ini';
          if (!in_array($apacheIni, $iniFiles)) {
            $iniFiles[] = $apacheIni;
            colorLog("Added Apache PHP configuration: $apacheIni", 's');
          }
        }
      }
    }

    // Add or update the sources_path configuration
    foreach ($iniFiles as $iniFile) {
      // Check if file exists and is writable
      if (!file_exists($iniFile)) {
        // Create the file if it doesn't exist
        $iniDir = dirname($iniFile);
        if (!is_dir($iniDir)) {
          execute_command("mkdir -p " . escapeshellarg($iniDir));
        }
        file_put_contents($iniFile, "extension=ddtrace.so\n");
        colorLog("Created new INI file: $iniFile", 's');
      }

      // Read existing content
      $iniContent = file_get_contents($iniFile);

      // Check for and prevent duplicate extension entries
      if (substr_count($iniContent, 'extension=ddtrace.so') > 1) {
        $iniContent = preg_replace('/extension=ddtrace\.so\s+extension=ddtrace\.so/m', 'extension=ddtrace.so', $iniContent);
        colorLog("Fixed duplicate extension entries in: $iniFile", 'w');
      }

      // Check if sources_path is already set
      if (preg_match('/datadog\.trace\.sources_path\s*=/', $iniContent)) {
        // Update existing setting
        $iniContent = preg_replace(
          '/datadog\.trace\.sources_path\s*=\s*[^\n]*/',
          "datadog.trace.sources_path = $sourceDir",
          $iniContent
        );
        colorLog("Updated datadog.trace.sources_path in: $iniFile", 's');
      } else {
        // Add new setting
        $iniContent .= "\n; Path to Datadog PHP tracer source files\ndatadog.trace.sources_path = $sourceDir\n";
        colorLog("Added datadog.trace.sources_path to: $iniFile", 's');
      }

      // Write the updated content back to the file
      file_put_contents($iniFile, $iniContent);
    }

    colorLog("Configuration updated for: $binaryForLog", 's');
  }

  // Clean up temporary directory
  execute_command((IS_WINDOWS ? "rd /s /q " : "rm -rf ") . escapeshellarg($tmpDir));

  return $flag;
}

/**
 * Helper function to safely copy extension files with proper permissions
 */
function safe_copy_extension($source, $destination)
{
  if (!file_exists($source)) {
    throw new RuntimeException("Source extension file does not exist: $source");
  }

  // Create destination directory if it doesn't exist
  $destDir = dirname($destination);
  if (!is_dir($destDir)) {
    if (!mkdir($destDir, 0755, true)) {
      throw new RuntimeException("Failed to create destination directory: $destDir");
    }
  }

  // Copy the file
  if (!copy($source, $destination)) {
    throw new RuntimeException("Failed to copy extension from $source to $destination");
  }

  // Set proper permissions on Linux
  if (!IS_WINDOWS) {
    chmod($destination, 0755);
  }

  colorLog("Successfully copied extension to $destination", 's');
}

/**
 * Helper function to check if an extension is installed
 */
function check_extension_installed($binary, $extension): bool
{
  $output = shell_exec(escapeshellarg($binary) . " -m");
  if ($output === null) {
    return false;
  }

  $modules = explode("\n", $output);
  $modules = array_map('trim', $modules);

  return in_array($extension, $modules);
}

/**
 * Helper function to find PHP Apache config directories
 */
function findPhpApacheConfigDir()
{
  $possibleLocations = [
    '/etc/php/*/apache2/conf.d',
    '/etc/php/*/cli/conf.d',
    '/etc/php-*/conf.d',
    '/etc/php.d',
    '/usr/local/etc/php/conf.d'
  ];

  foreach ($possibleLocations as $pattern) {
    $paths = glob($pattern);
    if (!empty($paths)) {
      return $paths[0]; // Return the first match
    }
  }

  return null;
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

function get_or_create_base_dir(): string
{
  if (!is_dir(BASE_DIR)) {
    colorLog("Creating base directory structure: " . BASE_DIR, 'i');
    if (IS_WINDOWS) {
      execute_command("mkdir " . escapeshellarg(BASE_DIR));
    } else {
      execute_command("mkdir -p " . escapeshellarg(BASE_DIR));
    }
  }

  return BASE_DIR;
}

function install_wordpress_specific($selectedBinaries): void
{
  // Define standard installation directories
  $baseDir = get_or_create_base_dir();
  $wordpressDir = $baseDir . '/wordpress';

  if (!is_dir($wordpressDir)) {
    colorLog("Creating WordPress directory: $wordpressDir", 'i');
    if (IS_WINDOWS) {
      execute_command("mkdir " . escapeshellarg($wordpressDir));
    } else {
      execute_command("mkdir -p " . escapeshellarg($wordpressDir));
    }
  }

  global $ARGS;

  $packages = get_project_packages(PROJECT_TYPE_WORDPRESS);
  $composer = get_composer_command();

  // Initialize new composer project for WordPress
  $composerCmd = "$composer init --name \"middleware-labs/wp-auto-instrumentation\" " .
    '--no-interaction';
  execute_command($composerCmd);

  // Install packages
  $require_cmd = "$composer require " . implode(' ', $packages) . " --no-interaction";
  execute_command($require_cmd);

  // Copy vendor to otel directory
  copyOrMoveDirectory("vendor", $wordpressDir, "move");

  $configDir = array();

  foreach ($selectedBinaries as $command => $fullPath) {
    $phpProperties = ini_values($fullPath);
    $iniFile = getApacheConfDir($phpProperties);

    if (!empty($iniFile)) {
      array_push($configDir, $iniFile);
    } else {
      $fallback = isset($ARGS[ADD_INI_DIRS])
        ? $ARGS[ADD_INI_DIRS]
        : findPhpApacheConfigDir();

      array_push($configDir, $fallback);
    }
  }

  // Configure WordPress
  configure_wordpress($configDir, $wordpressDir);
}

function getApacheConfDir($phpProperties): string
{
  $ini_dir = $phpProperties[INI_SCANDIR];

  if (strpos($ini_dir, '/cli/conf.d') !== false) {
    $apacheConfd = str_replace('/cli/conf.d', '/apache2/conf.d', $ini_dir);
    if (file_exists($apacheConfd)) {
      return str_replace('/cli/conf.d', '/apache2/conf.d', $ini_dir);
    }
  }

  return "";
}

function configure_wordpress(array $configDir, string $wordpressDir): void
{
  $content = "auto_prepend_file=$wordpressDir/autoload.php";

  foreach ($configDir as $cd) {
    $filename = "$cd/mw.wordpress.ini";

    if (file_exists($filename))
      continue;

    if (file_put_contents($filename, $content, FILE_APPEND) === false) {
      colorLog("Failed to write to INI file: $filename");
    }

    colorLog("Created $cd/mw.wordpress.ini");
  }

  try {
    setOpenTelemetryEnvVariables();
  } catch (\Throwable $th) {
    colorLog("Please set ENVIRONMENT variables and restart your APACHE/NGINX server. (See docs for more info)", "w");
  }
}

function get_supported_php_versions()
{
  return ['7.0', '7.1', '7.2', '7.3', '7.4', '8.0', '8.1', '8.2', '8.3'];
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

  // Get PHP info with timezone set to avoid warnings
  exec(escapeshellarg($binary) . " -d date.timezone=UTC -i", $lines);
  $found = [];

  // Parse PHP info
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

  // If extension_dir wasn't found in the parsed output, try more direct approaches
  if (!isset($found[EXTENSION_DIR]) || empty($found[EXTENSION_DIR])) {
    // Try to get extension_dir using php -r
    $ext_dir = trim(shell_exec($binary . ' -r "echo ini_get(\"extension_dir\");"'));
    if (!empty($ext_dir)) {
      $found[EXTENSION_DIR] = $ext_dir;
    } else {
      // Last resort: try to find it in the output more flexibly
      foreach ($lines as $line) {
        if (strpos($line, 'extension_dir') !== false && strpos($line, '=>') !== false) {
          $parts = explode('=>', $line);
          $found[EXTENSION_DIR] = trim($parts[1]);
          break;
        }
      }
    }
  }

  // If extension_dir is still empty, use the default path
  if (!isset($found[EXTENSION_DIR]) || $found[EXTENSION_DIR] == "") {
    $found[EXTENSION_DIR] = dirname(PHP_BINARY);
  } elseif ($found[EXTENSION_DIR][0] != "/" && (!IS_WINDOWS || !preg_match('~^([A-Z]:[\\\\/]|\\\\{2})~i', $found[EXTENSION_DIR]))) {
    $found[EXTENSION_DIR] = dirname(PHP_BINARY) . '/' . $found[EXTENSION_DIR];
  }

  return $found;
}

function is_extension_installed($binary, $extension): bool
{
  $modules = explode("\n", shell_exec("$binary -m") ?: '');
  return in_array($extension, $modules);
}

function get_ini_files(array $phpProperties, $extension = 'opentelemetry')
{
  global $ARGS;

  $ini_files = [];

  if (isset($ARGS[ADD_INI_DIRS])) {
    foreach ($ARGS[ADD_INI_DIRS] as $dir) {
      array_push($ini_files, $dir . DIRECTORY_SEPARATOR . $extension . '.ini');
    }
  }

  $ini_dir = $phpProperties[INI_SCANDIR] ?? null;

  if (!isset($ini_dir)) {
    array_push($ini_files, $phpProperties[INI_MAIN]);
    return $ini_files;
  }

  array_push($ini_files, $ini_dir . DIRECTORY_SEPARATOR . $extension . '.ini');
  if (strpos($ini_dir, '/cli/conf.d') !== false) {
    $apacheConfd = str_replace('/cli/conf.d', '/apache2/conf.d', $ini_dir);
    $apacheIni = $apacheConfd . DIRECTORY_SEPARATOR . $extension . '.ini';

    if (file_exists($apacheConfd) && !file_exists($apacheIni)) {
      array_push($ini_files, $apacheIni);
    }

    $fpmConfd = str_replace('/cli/conf.d', '/fpm/conf.d', $ini_dir);
    if (file_exists(($fpmConfd))) {
      array_push($ini_files, $fpmConfd . DIRECTORY_SEPARATOR . $extension . '.ini');
    }
  }

  return $ini_files;
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

function setDatadogEnvVariables()
{
  // Define Datadog environment variables with appropriate fallbacks
  $env_vars = [
    'DD_SERVICE' => getenv("DD_SERVICE") ?: getenv('OTEL_SERVICE_NAME') ?: getenv('MW_SERVICE_NAME') ?: 'service-' . getmypid(),
    'DD_TRACE_AGENT_URL' => getenv("DD_TRACE_AGENT_URL") ?: 'http://localhost:8126',
    'DD_TRACE_DEBUG' => getenv("DD_TRACE_DEBUG") ?: '0',
    'DD_ENV' => getenv("DD_ENV") ?: 'production',
    'DD_VERSION' => getenv("DD_VERSION") ?: '1.0.0'
  ];

  // For Apache
  if (file_exists(APACHE_ENV_FILE)) {
    $envVarsContent = "\n# Datadog APM Environment Variables\n";
    $envVarsContent .= implode("\n", array_map(function ($k, $v) {
      return "export $k=\"$v\"";
    }, array_keys($env_vars), $env_vars)) . "\n";

    file_put_contents(APACHE_ENV_FILE, $envVarsContent, FILE_APPEND);
    colorLog("Added Datadog environment variables to Apache environment file", "s");

    // Restart Apache to apply the changes
    if (function_exists('exec')) {
      exec('service apache2 restart 2>/dev/null || httpd -k restart 2>/dev/null || systemctl restart apache2 2>/dev/null || systemctl restart httpd 2>/dev/null', $output, $resultCode);
      if ($resultCode === 0) {
        colorLog("Apache restarted successfully with new Datadog environment variables.", "s");
      } else {
        colorLog("Failed to restart Apache. You may need to restart it manually.", "w");
      }
    }
  }

  // For PHP-FPM
  $fpmConfigPaths = [
    '/etc/php-fpm.d/www.conf',
    '/etc/php-fpm.conf',
    '/etc/php/*/fpm/php-fpm.conf',
    '/etc/php/*/fpm/pool.d/www.conf'
  ];

  $fpmConfigFound = false;
  foreach ($fpmConfigPaths as $pattern) {
    $paths = glob($pattern);
    if (empty($paths)) {
      continue;
    }

    foreach ($paths as $fpmConfigPath) {
      if (file_exists($fpmConfigPath)) {
        $fpmConfigFound = true;
        $envVarsContent = "\n; Datadog APM Environment Variables\n";
        foreach ($env_vars as $key => $value) {
          $envVarsContent .= "env[$key] = \"$value\"\n";
        }

        file_put_contents($fpmConfigPath, $envVarsContent, FILE_APPEND);
        colorLog("Added Datadog environment variables to PHP-FPM config: $fpmConfigPath", "s");
      }
    }
  }

  if ($fpmConfigFound) {
    // Restart PHP-FPM
    if (function_exists('exec')) {
      exec('service php-fpm restart 2>/dev/null || service php*-fpm restart 2>/dev/null || systemctl restart php-fpm 2>/dev/null || systemctl restart php*-fpm 2>/dev/null', $output, $resultCode);
      if ($resultCode === 0) {
        colorLog("PHP-FPM restarted successfully with new Datadog environment variables.", "s");
      } else {
        colorLog("Failed to restart PHP-FPM. You may need to restart it manually.", "w");
      }
    }
  }

  // Create a .env file for applications that use it (Laravel, etc.)
  global $PROJECT_TYPE;
  if ($PROJECT_TYPE === PROJECT_TYPE_LARAVEL) {
    $envFile = '.env';
    $envContent = "";

    if (file_exists($envFile)) {
      $envContent = file_get_contents($envFile);
    }

    foreach ($env_vars as $key => $value) {
      // Check if variable already exists in .env
      if (preg_match('/^' . preg_quote($key) . '=/m', $envContent)) {
        // Replace existing variable
        $envContent = preg_replace('/^' . preg_quote($key) . '=.*$/m', "$key=\"$value\"", $envContent);
      } else {
        // Add new variable
        $envContent .= "\n$key=\"$value\"";
      }
    }

    file_put_contents($envFile, $envContent);
    colorLog("Added Datadog environment variables to .env file", "s");
  }

  // Show instructions for manual setup
  if (!file_exists(APACHE_ENV_FILE) && !$fpmConfigFound) {
    colorLog("No server configuration files found. You'll need to set environment variables manually.", "w");
    colorLog("Required Datadog environment variables:", "i");
    foreach ($env_vars as $key => $value) {
      colorLog("export $key=\"$value\"", "i");
    }
  }

  // Set environment variables for current process (useful for CLI operations)
  foreach ($env_vars as $key => $value) {
    putenv("$key=$value");
  }
}

function setOpenTelemetryEnvVariables()
{
  // Define OpenTelemetry environment variables with appropriate fallbacks
  $env_vars = [
    'OTEL_PHP_AUTOLOAD_ENABLED' => getenv('OTEL_PHP_AUTOLOAD_ENABLED') ?: 'true',
    'OTEL_TRACES_EXPORTER' => getenv('OTEL_TRACES_EXPORTER') ?: 'otlp',
    'OTEL_EXPORTER_OTLP_PROTOCOL' => getenv('OTEL_EXPORTER_OTLP_PROTOCOL') ?: 'http/json',
    'OTEL_PROPAGATORS' => getenv('OTEL_PROPAGATORS') ?: 'baggage,tracecontext',
    'OTEL_SERVICE_NAME' => getenv("OTEL_SERVICE_NAME") ?: getenv('MW_SERVICE_NAME') ?: 'service-' . getmypid(),
    'OTEL_EXPORTER_OTLP_ENDPOINT' => getenv("OTEL_EXPORTER_OTLP_ENDPOINT") ?: getenv("MW_TARGET") ?: 'http://localhost:9320'
  ];

  // For Apache
  if (file_exists(APACHE_ENV_FILE)) {
    $envVarsContent = "\n# OpenTelemetry Environment Variables\n";
    $envVarsContent .= $envVarsContent .= implode("\n", array_map(function ($k, $v) {
      return "export $k=\"$v\"";
    }, array_keys($env_vars), $env_vars)) . "\n";

    file_put_contents(APACHE_ENV_FILE, $envVarsContent, FILE_APPEND);
    colorLog("Added OpenTelemetry environment variables to Apache environment file", "s");

    // Restart Apache to apply the changes
    restartApacheServer();
  }

  // For PHP-FPM
  $fpmConfigPaths = [
    '/etc/php-fpm.d/www.conf',
    '/etc/php-fpm.conf',
    '/etc/php/*/fpm/php-fpm.conf',
    '/etc/php/*/fpm/pool.d/www.conf'
  ];

  $fpmConfigFound = false;
  foreach ($fpmConfigPaths as $pattern) {
    $paths = glob($pattern);
    if (empty($paths)) {
      continue;
    }

    foreach ($paths as $fpmConfigPath) {
      if (file_exists($fpmConfigPath)) {
        $fpmConfigFound = true;
        $envVarsContent = "\n; OpenTelemetry Environment Variables\n";
        foreach ($env_vars as $key => $value) {
          $envVarsContent .= "env[$key] = \"$value\"\n";
        }

        file_put_contents($fpmConfigPath, $envVarsContent, FILE_APPEND);
        colorLog("Added OpenTelemetry environment variables to PHP-FPM config: $fpmConfigPath", "s");
      }
    }
  }

  if ($fpmConfigFound) {
    // Restart PHP-FPM
    restartPhpFpmService();
  }

  // Create a .env file for applications that use it (Laravel, etc.)
  global $PROJECT_TYPE;
  if ($PROJECT_TYPE === PROJECT_TYPE_LARAVEL) {
    $envFile = '.env';
    $envContent = "";

    if (file_exists($envFile)) {
      $envContent = file_get_contents($envFile);
    }

    foreach ($env_vars as $key => $value) {
      // Check if variable already exists in .env
      if (preg_match('/^' . preg_quote($key) . '=/m', $envContent)) {
        // Replace existing variable
        $envContent = preg_replace('/^' . preg_quote($key) . '=.*$/m', "$key=\"$value\"", $envContent);
      } else {
        // Add new variable
        $envContent .= "\n$key=\"$value\"";
      }
    }

    file_put_contents($envFile, $envContent);
    colorLog("Added OpenTelemetry environment variables to .env file", "s");
  }

  // Show instructions for manual setup
  if (!file_exists(APACHE_ENV_FILE) && !$fpmConfigFound) {
    colorLog("No server configuration files found. You'll need to set OpenTelemetry environment variables manually.", "w");
    colorLog("Required OpenTelemetry environment variables:", "i");
    foreach ($env_vars as $key => $value) {
      colorLog("export $key=\"$value\"", "i");
    }
  }

  // Set environment variables for current process (useful for CLI operations)
  foreach ($env_vars as $key => $value) {
    putenv("$key=$value");
  }
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

function get_architecture()
{
  // For Windows systems
  if (IS_WINDOWS) {
    if (PHP_INT_SIZE === 4) {
      // 32-bit architecture
      return "x86";
    } else {
      // 64-bit architecture
      if ($env = getenv("PROCESSOR_ARCHITECTURE")) {
        return $env === "AMD64" ? "x86_64" : strtolower($env);
      }
      // Default fallback for 64-bit Windows
      return "x86_64";
    }
  }

  // For Linux/Unix systems
  // Try using uname command first (most reliable)
  $arch = trim(shell_exec("uname -m 2>/dev/null"));
  if (!empty($arch)) {
    return $arch;
  }

  return execute_command("uname -m");
}

function is_alpine()
{
  if (IS_WINDOWS) {
    return false;
  }

  $osInfoFile = '/etc/os-release';
  // if /etc/os-release is not readable then assume it's not alpine.
  if (!is_readable($osInfoFile)) {
    return false;
  }
  return false !== stripos(file_get_contents($osInfoFile), 'alpine');
}

function execute_command(string $cmd, bool $continueOnError = false): bool|string
{
  colorLog("Executing: $cmd", 'i');
  $output = null;
  $result_code = null;
  $lastLine = exec($cmd, $output, $result_code);
  if ($lastLine === false || $result_code > 0) {
    $out = "";
    foreach ($output as $line) {
      $out .= "$line\n";
    }
    colorLog($out, 'e');
    if (!$continueOnError) {
      throw new RuntimeException("Command failed with exit code {$result_code}");
    }
  }

  return $lastLine;
}

function is_truthy($value)
{
  if ($value === null) {
    return false;
  }

  // Convert to string if not already and trim whitespace
  $normalized = trim(strtolower((string) $value));

  // Check against common "truthy" values
  return in_array($normalized, [
    '1',
    'true',
    'yes',
    'y',
    'on',
    'enabled',
    't'
  ]);
}

/**
 * Updates the uninstall_datadog_apm function to delete INI files
 * @param array $selectedBinaries Array of PHP binaries to uninstall from
 * @return bool Success status
 */
function uninstall_datadog_apm($selectedBinaries): bool
{
  colorLog("Starting Datadog APM uninstallation...", 'i');
  $success = true;

  foreach ($selectedBinaries as $command => $fullPath) {
    $binaryForLog = ($command === $fullPath) ? $fullPath : "$command ($fullPath)";
    colorLog("Uninstalling Datadog APM from binary: $binaryForLog", 'i');

    $phpProperties = ini_values($fullPath);

    // Get extension directory
    $extensionDir = $phpProperties[EXTENSION_DIR] ?? '/usr/lib/php';

    // Files to remove
    $extensionFiles = [
      $extensionDir . '/' . (IS_WINDOWS ? "php_" : "") . 'ddtrace.' . (IS_WINDOWS ? "dll" : "so"),
      $extensionDir . '/' . (IS_WINDOWS ? "php_" : "") . 'datadog-profiling.' . (IS_WINDOWS ? "dll" : "so"),
      $extensionDir . '/' . (IS_WINDOWS ? "php_" : "") . 'ddappsec.' . (IS_WINDOWS ? "dll" : "so")
    ];

    // Get all relevant INI files
    $iniFiles = get_ini_files($phpProperties, 'ddtrace');

    // For Apache, try to detect PHP configuration directory
    if (strpos($command, 'apache') !== false || strpos($binaryForLog, 'apache') !== false) {
      // Common Apache PHP configuration directories
      $apacheDirs = [
        '/etc/php/*/apache2/conf.d',
        '/etc/php-apache/conf.d',
        '/etc/php.d/apache',
        '/etc/php-*/conf.d/apache'
      ];

      foreach ($apacheDirs as $pattern) {
        $dirs = glob($pattern, GLOB_ONLYDIR);
        if (!empty($dirs)) {
          foreach ($dirs as $dir) {
            $apacheIni = $dir . '/ddtrace.ini';
            if (!in_array($apacheIni, $iniFiles)) {
              $iniFiles[] = $apacheIni;
            }
          }
        }
      }
    }

    // Also check for specific Apache configuration in INI scan dir
    if (isset($phpProperties[INI_SCANDIR])) {
      $scanDir = $phpProperties[INI_SCANDIR];

      // Check for Apache-specific config directories
      if (strpos($scanDir, '/cli/conf.d') !== false) {
        $apacheConfd = str_replace('/cli/conf.d', '/apache2/conf.d', $scanDir);
        if (is_dir($apacheConfd)) {
          $apacheIni = $apacheConfd . '/ddtrace.ini';
          if (!in_array($apacheIni, $iniFiles)) {
            $iniFiles[] = $apacheIni;
          }
        }
      }
    }

    // Process INI files - DELETE Datadog-specific files
    foreach ($iniFiles as $iniFile) {
      if (file_exists($iniFile)) {
        colorLog("Processing INI file: $iniFile", 'i');

        // Check if this is a Datadog-specific file we should delete
        $fileName = basename($iniFile);
        if (
          $fileName === 'ddtrace.ini' || $fileName === '98-ddtrace.ini' ||
          strpos($fileName, 'datadog') !== false || strpos($fileName, 'dd-') !== false
        ) {
          // This is a Datadog-specific INI file, delete it
          if (unlink($iniFile)) {
            colorLog("Deleted Datadog INI file: $iniFile", 's');
          } else {
            colorLog("Failed to delete INI file: $iniFile", 'e');
            $success = false;
          }
        } else {
          // This is a shared INI file, comment out Datadog settings
          $iniContent = file_get_contents($iniFile);
          $patterns = [
            '/(^\s*)(extension\s*=\s*.*ddtrace.*)$/m',
            '/(^\s*)(extension\s*=\s*.*datadog-profiling.*)$/m',
            '/(^\s*)(extension\s*=\s*.*ddappsec.*)$/m',
            '/(^\s*)(datadog\..*\s*=.*)$/m'
          ];

          foreach ($patterns as $pattern) {
            $iniContent = preg_replace($pattern, '$1;$2 # Commented out by Datadog uninstaller', $iniContent);
          }

          if (file_put_contents($iniFile, $iniContent) === false) {
            colorLog("Failed to update INI file: $iniFile", 'e');
            $success = false;
          } else {
            colorLog("Commented out Datadog settings in shared INI file: $iniFile", 's');
          }
        }
      }
    }

    // Remove extension files
    foreach ($extensionFiles as $file) {
      if (file_exists($file)) {
        if (unlink($file)) {
          colorLog("Removed extension file: $file", 's');
        } else {
          colorLog("Failed to remove extension file: $file", 'e');
          $success = false;
        }
      }
    }
  }

  // Remove source files
  $installDirs = [
    '/opt/datadog/dd-library/1.8.2',
    '/opt/datadog/dd-library'
  ];

  foreach ($installDirs as $dir) {
    if (is_dir($dir)) {
      colorLog("Removing installation directory: $dir", 'i');
      if (IS_WINDOWS) {
        execute_command("rd /s /q " . escapeshellarg($dir), true);
      } else {
        execute_command("rm -rf " . escapeshellarg($dir), true);
      }
    }
  }

  if ($success) {
    colorLog("Datadog APM has been successfully uninstalled, , please restart your apache / fpm server", 's');
  } else {
    colorLog("Datadog APM uninstallation completed with some errors", 'w');
  }

  return $success;
}

/**
 * Updates the uninstall_opentelemetry_apm function to delete INI files
 * @param array $selectedBinaries Array of PHP binaries to uninstall from
 * @return bool Success status
 */
function uninstall_opentelemetry_apm($selectedBinaries): bool
{
  colorLog("Starting OpenTelemetry APM uninstallation...", 'i');
  $success = true;

  foreach ($selectedBinaries as $command => $fullPath) {
    $binaryForLog = ($command === $fullPath) ? $fullPath : "$command ($fullPath)";
    colorLog("Uninstalling OpenTelemetry APM from binary: $binaryForLog", 'i');

    $phpProperties = ini_values($fullPath);

    // Get extension directory
    $extensionDir = $phpProperties[EXTENSION_DIR] ?? '/usr/lib/php';

    // Files to remove
    $extensionFiles = [
      $extensionDir . '/' . (IS_WINDOWS ? "php_" : "") . 'opentelemetry.' . (IS_WINDOWS ? "dll" : "so")
    ];

    // Get all relevant INI files
    $iniFiles = get_ini_files($phpProperties, 'opentelemetry');

    // For Apache, also get WordPress specific files
    if (isset($phpProperties[INI_SCANDIR])) {
      $scanDir = $phpProperties[INI_SCANDIR];

      // Add WordPress config if it exists
      $wpConfig = dirname($scanDir) . '/mw.wordpress.ini';
      if (file_exists($wpConfig) && !in_array($wpConfig, $iniFiles)) {
        $iniFiles[] = $wpConfig;
      }

      // Check for Apache-specific config directories
      if (strpos($scanDir, '/cli/conf.d') !== false) {
        $apacheConfd = str_replace('/cli/conf.d', '/apache2/conf.d', $scanDir);
        if (is_dir($apacheConfd)) {
          $apacheIni = $apacheConfd . '/opentelemetry.ini';
          if (!in_array($apacheIni, $iniFiles)) {
            $iniFiles[] = $apacheIni;
          }

          // WordPress config for Apache
          $wpConfig = $apacheConfd . '/mw.wordpress.ini';
          if (file_exists($wpConfig) && !in_array($wpConfig, $iniFiles)) {
            $iniFiles[] = $wpConfig;
          }
        }
      }
    }

    // Process INI files - DELETE OpenTelemetry-specific files
    foreach ($iniFiles as $iniFile) {
      if (file_exists($iniFile)) {
        colorLog("Processing INI file: $iniFile", 'i');

        // Check if this is an OpenTelemetry-specific file we should delete
        $fileName = basename($iniFile);
        if (
          $fileName === 'opentelemetry.ini' || $fileName === 'mw.wordpress.ini' ||
          strpos($fileName, 'otel') !== false || strpos($fileName, 'middleware') !== false
        ) {
          // This is an OpenTelemetry-specific INI file, delete it
          if (unlink($iniFile)) {
            colorLog("Deleted OpenTelemetry INI file: $iniFile", 's');
          } else {
            colorLog("Failed to delete INI file: $iniFile", 'e');
            $success = false;
          }
        } else {
          // This is a shared INI file, comment out OpenTelemetry settings
          $iniContent = file_get_contents($iniFile);
          $patterns = [
            '/(^\s*)(extension\s*=\s*.*opentelemetry.*)$/m',
            '/(^\s*)(auto_prepend_file\s*=\s*.*)$/m',
            '/(^\s*)(OTEL_.*\s*=.*)$/m'
          ];

          foreach ($patterns as $pattern) {
            $iniContent = preg_replace($pattern, '$1;$2 # Commented out by OpenTelemetry uninstaller', $iniContent);
          }

          if (file_put_contents($iniFile, $iniContent) === false) {
            colorLog("Failed to update INI file: $iniFile", 'e');
            $success = false;
          } else {
            colorLog("Commented out OpenTelemetry settings in shared INI file: $iniFile", 's');
          }
        }
      }
    }

    // Remove extension files
    foreach ($extensionFiles as $file) {
      if (file_exists($file)) {
        if (unlink($file)) {
          colorLog("Removed extension file: $file", 's');
        } else {
          colorLog("Failed to remove extension file: $file", 'e');
          $success = false;
        }
      }
    }
  }

  // Framework-specific uninstallation
  global $PROJECT_TYPE;
  if ($PROJECT_TYPE === PROJECT_TYPE_WORDPRESS) {
    // Remove WordPress auto-instrumentation directory
    $wordPressDir = BASE_DIR . '/wordpress';
    if (is_dir($wordPressDir)) {
      colorLog("Removing OpenTelemetry WordPress directory: $wordPressDir", 'i');
      if (IS_WINDOWS) {
        execute_command("rd /s /q " . escapeshellarg($wordPressDir), true);
      } else {
        execute_command("rm -rf " . escapeshellarg($wordPressDir), true);
      }
    }

    // Also look for and remove composer.json and vendor directory created for WordPress
    if (file_exists('composer.json')) {
      $composerContent = file_get_contents('composer.json');
      if (strpos($composerContent, 'middleware-labs/wp-auto-instrumentation') !== false) {
        unlink('composer.json');
        colorLog("Removed OpenTelemetry WordPress composer.json", 's');

        if (file_exists('composer.lock')) {
          unlink('composer.lock');
          colorLog("Removed composer.lock", 's');
        }
      }
    }
  } elseif ($PROJECT_TYPE === PROJECT_TYPE_LARAVEL) {
    // Remove Laravel packages
    try {
      $composer = get_composer_command();
      $packagesToRemove = [
        'open-telemetry/sdk',
        'open-telemetry/exporter-otlp',
        'php-http/guzzle7-adapter',
        'open-telemetry/api',
        'middleware-labs/contrib-auto-laravel',
        'open-telemetry/extension-propagator-b3',
        'Middleware/laravel-apm'
      ];

      $removeCmd = "$composer remove " . implode(' ', $packagesToRemove) . " --no-interaction";
      execute_command($removeCmd, true);
      colorLog("Removed OpenTelemetry packages from Laravel project", 's');
    } catch (Exception $e) {
      colorLog("Error removing Laravel packages: " . $e->getMessage(), 'w');
    }
  }

  // Remove environment variables from environment files
  // clean_opentelemetry_environment_variables();
  // restartApacheServer();
  // restartPhpFpmService();

  if ($success) {
    colorLog("OpenTelemetry APM has been successfully uninstalled, please restart your apache / fpm server", 's');
  } else {
    colorLog("OpenTelemetry APM uninstallation completed with some errors", 'w');
  }

  return $success;
}

/**
 * Restart apache2 service
 * @return bool Success status
 */
function restartApacheServer(): bool
{
  if (!function_exists('exec')) {
    colorLog("Cannot restart Apache - exec function is disabled", "w");
    return false;
  }

  colorLog("Attempting to restart Apache...", "i");
  exec('service apache2 restart 2>/dev/null || httpd -k restart 2>/dev/null || systemctl restart apache2 2>/dev/null || systemctl restart httpd 2>/dev/null', $output, $resultCode);

  if ($resultCode === 0) {
    colorLog("Apache restarted successfully.", "s");
    return true;
  } else {
    colorLog("Failed to restart Apache. You will need to restart it manually.", "w");
    return false;
  }
}

/**
 * Restart PHP-FPM service
 * @return bool Success status
 */
function restartPhpFpmService(): bool
{
  if (!function_exists('exec')) {
    colorLog("Cannot restart PHP-FPM - exec function is disabled", "w");
    return false;
  }

  colorLog("Attempting to restart PHP-FPM...", "i");
  exec('service php-fpm restart 2>/dev/null || service php*-fpm restart 2>/dev/null || systemctl restart php-fpm 2>/dev/null || systemctl restart php*-fpm 2>/dev/null', $output, $resultCode);

  if ($resultCode === 0) {
    colorLog("PHP-FPM restarted successfully.", "s");
    return true;
  } else {
    colorLog("Failed to restart PHP-FPM. You will need to restart it manually.", "w");
    return false;
  }
}
