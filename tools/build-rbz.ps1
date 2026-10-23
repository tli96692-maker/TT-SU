# 默认保留本地完整离线包；-Core 是公开核心包；-Lite 同样仅提供第三方官网入口。
param([string]$Root = '', [switch]$Lite, [switch]$Core, [string]$Repository = '')
$ErrorActionPreference = 'Stop'
if ($Lite -and $Core) { throw '-Lite 和 -Core 不能同时使用' }
if ($Repository -and $Repository -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$') { throw 'Repository 必须是 GitHub owner/repo，不是 URL' }
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
$sourceRoot = Join-Path $Root 'src'
$distRoot = Join-Path $Root 'dist'
$stageRoot = Join-Path $distRoot ('stage-' + [Guid]::NewGuid().ToString('N'))
$namespaceRoot = Join-Path $stageRoot 'su_zhongshu'
$artifactName = if ($Core) { 'su_zhongshu-core.rbz' } elseif ($Lite) { 'su_zhongshu-lite.rbz' } else { 'su_zhongshu.rbz' }
$artifactPath = Join-Path $distRoot $artifactName
$utf8 = [Text.UTF8Encoding]::new($false)
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'su_zhongshu.rb'))) { throw '缺少 src/su_zhongshu.rb' }
New-Item -ItemType Directory -Force -Path $namespaceRoot | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'su_zhongshu.rb') -Destination $stageRoot
    foreach ($folderName in @('hub', 'ui')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $folderName) -Destination $namespaceRoot -Recurse
    }
    if ($Core -or $Lite) {
        $pluginRoot = Join-Path $namespaceRoot 'plugins'
        New-Item -ItemType Directory -Force -Path $pluginRoot | Out-Null
        foreach ($id in @('su-demo-stats','su-roundcorner','su-pushpull','su-loft','su-terrain','su-paint','su-scale')) {
            Copy-Item -LiteralPath (Join-Path $sourceRoot ('plugins/' + $id)) -Destination $pluginRoot -Recurse
        }
        $catalog = Get-Content -LiteralPath (Join-Path $sourceRoot 'market/catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $catalog.PSObject.Properties.Remove('host')
        $catalog | Add-Member -NotePropertyName distribution -NotePropertyValue 'public-core-official-links' -Force
        foreach ($item in $catalog.plugins) {
            if (-not $item.homepage -or $item.homepage -notmatch '^https://[^/\s]+(?:/|$)') { throw ('缺少有效官方入口: ' + $item.id) }
            $item | Add-Member -NotePropertyName official -NotePropertyValue $true -Force
            foreach ($field in @('url','sha256','integration','adapter_version','changelog')) { $item.PSObject.Properties.Remove($field) }
        }
        $marketRoot = Join-Path $namespaceRoot 'market'
        New-Item -ItemType Directory -Force -Path $marketRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $marketRoot 'catalog.json'), ($catalog | ConvertTo-Json -Depth 32), $utf8)
        $blocked = @(Get-ChildItem -LiteralPath $namespaceRoot -Recurse -File | Where-Object { $_.Extension.ToLowerInvariant() -in @('.zip','.rbz','.dll','.exe','.so','.dylib') -or $_.FullName -match '[\\/]vendor[\\/]' })
        if ($blocked.Count) { throw '公开包中出现第三方归档或二进制；拒绝生成' }
    } else {
        foreach ($folderName in @('plugins', 'market')) {
            Copy-Item -LiteralPath (Join-Path $sourceRoot $folderName) -Destination $namespaceRoot -Recurse
        }
    }
    foreach ($notice in @('LICENSE','THIRD_PARTY_NOTICES.md')) {
        Copy-Item -LiteralPath (Join-Path $Root $notice) -Destination $namespaceRoot
    }
    $releaseConfig = Get-Content -LiteralPath (Join-Path $sourceRoot 'release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Repository) { $releaseConfig.repository = $Repository }
    [IO.File]::WriteAllText((Join-Path $namespaceRoot 'release.json'), ($releaseConfig | ConvertTo-Json -Depth 8), $utf8)
    Get-ChildItem -LiteralPath $stageRoot -File -Recurse -Force | Where-Object { $_.Name -in @('.DS_Store','Thumbs.db') -or $_.Extension -in @('.log','.tmp') } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $distRoot ('package-' + [Guid]::NewGuid().ToString('N') + '.zip')
    [IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    Move-Item -LiteralPath $zipPath -Destination $artifactPath -Force
    Write-Host ('已生成 {0} ({1:N1} KB)' -f $artifactPath, ((Get-Item -LiteralPath $artifactPath).Length / 1KB))
} finally {
    $resolvedStage = [IO.Path]::GetFullPath($stageRoot)
    $resolvedDist = [IO.Path]::GetFullPath($distRoot)
    if (-not $resolvedStage.StartsWith($resolvedDist + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '拒绝清理工作区外路径' }
    if (Test-Path -LiteralPath $resolvedStage) { Remove-Item -LiteralPath $resolvedStage -Recurse -Force }
}
$hashLines = @(Get-ChildItem -LiteralPath $distRoot -Filter '*.rbz' -File | Sort-Object Name | ForEach-Object {
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    '{0}  {1}' -f $hash, $_.Name
})
[IO.File]::WriteAllLines((Join-Path $distRoot 'SHA256SUMS.txt'), $hashLines, $utf8)
