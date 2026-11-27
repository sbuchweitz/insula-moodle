<?php
// The page visitors get while the container installs or upgrades Moodle.
//
// The lifecycle runs before Apache starts, so without this nothing answers on
// the site's port and the platform's proxy shows a bare "502 Bad Gateway" for
// the whole upgrade — minutes, or longer when a big site is moved. The
// lifecycle serves this router with PHP's built-in web server for exactly as
// long as the work takes, then stops it and Apache takes the port over.
//
// Every request gets the same 503 with Retry-After, so browsers, crawlers and
// the mobile app all see "temporarily unavailable", never an error. The page
// names the current step in plain words, never the Moodle version: that would
// only help someone fingerprint the site.
//
// The lifecycle writes the status file: line 1 the start time (Unix seconds),
// line 2 the current step.

$statusFile = getenv('INSULA_MOODLE_MAINT_STATUS') ?: '/var/cache/insula-moodle/maintenance.txt';
$lines = @file($statusFile, FILE_IGNORE_NEW_LINES) ?: [];
$started = (int) ($lines[0] ?? 0);
$step = trim((string) ($lines[1] ?? ''));

$elapsed = $started > 0 ? max(0, time() - $started) : 0;
$minutes = intdiv($elapsed, 60);
if ($minutes < 1) {
    $since = 'Started less than a minute ago.';
} elseif ($minutes === 1) {
    $since = 'Started a minute ago.';
} else {
    $since = "Started {$minutes} minutes ago.";
}

http_response_code(503);
header('Retry-After: 30');
header('Cache-Control: no-store');
header('Content-Type: text/html; charset=utf-8');
header('X-Robots-Tag: noindex');
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'HEAD') {
    return true;
}

$e = static fn(string $s): string => htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="15">
<meta name="robots" content="noindex">
<title>Site update in progress</title>
<style>
  :root { --bg: #f6f7f9; --card: #fff; --text: #1d2125; --muted: #5c6670; --accent: #0f6cbf; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #15181c; --card: #1f2328; --text: #e6e8eb; --muted: #a3acb6; --accent: #5aa9f0; }
  }
  html, body { margin: 0; background: var(--bg); color: var(--text);
    font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 32rem; margin: 12vh auto 0; padding: 2rem 1.5rem; background: var(--card);
    border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  h1 { font-size: 1.35rem; margin: 0 0 .75rem; }
  p { margin: .5rem 0; }
  .step { color: var(--accent); font-weight: 600; }
  .muted { color: var(--muted); font-size: .9rem; }
  .bar { height: 4px; border-radius: 2px; background: color-mix(in srgb, var(--accent) 20%, transparent);
    overflow: hidden; margin: 1.25rem 0 .75rem; }
  .bar::after { content: ""; display: block; height: 100%; width: 35%; background: var(--accent);
    animation: slide 1.6s ease-in-out infinite; }
  @keyframes slide { from { transform: translateX(-100%); } to { transform: translateX(300%); } }
  @media (prefers-reduced-motion: reduce) { .bar::after { animation: none; width: 100%; opacity: .5; } }
</style>
</head>
<body>
<main role="status" aria-live="polite">
  <h1>This site is being updated</h1>
  <p>It will be back shortly. This page refreshes by itself.</p>
  <div class="bar" aria-hidden="true"></div>
<?php if ($step !== ''): ?>
  <p class="step"><?= $e($step) ?></p>
<?php endif; ?>
  <p class="muted"><?= $e($since) ?></p>
</main>
</body>
</html>
<?php
return true;
