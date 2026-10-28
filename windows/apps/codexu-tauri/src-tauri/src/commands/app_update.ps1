# Input is serialized JSON on stdin, never interpolated into script or arguments.
# This process has no access to account credentials. Only public release URLs.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Net.Http

function Test-Endpoint([string]$Value, [bool]$IsRedirect, [string]$Initial) {
    $u = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -ne 'https' -or $u.Port -ne 443 -or $u.UserInfo -or $u.Fragment) { return $false }
    if ($Value -ceq $Initial) { return $true }
    if (-not $IsRedirect) { return $false }
    if ($u.Host -notin @('release-assets.githubusercontent.com', 'objects.githubusercontent.com')) { return $false }
    return $u.AbsolutePath.StartsWith('/github-production-release-asset-', [StringComparison]::Ordinal)
}

$handler = $null; $client = $null; $response = $null; $source = $null; $destination = $null
try {
    $inputJson = [Console]::In.ReadToEnd()
    if ($inputJson.Length -gt 32768) { throw 'invalid_input' }
    $request = $inputJson | ConvertFrom-Json
    $url = [string]$request.url
    $limit = [long]$request.maximum_bytes
    if ($limit -le 0 -or $limit -gt 1073741824) { throw 'invalid_size' }
    $releaseApi = 'https://api.github.com/repos/BLACKIELF/AgentHub-AiGoodBro/releases/latest'
    $u = [Uri]$url
    $assetPattern = '^/BLACKIELF/(AgentHub-AiGoodBro|codex-account-manager-next)/releases/download/v?[0-9]+\.[0-9]+\.[0-9]+/[A-Za-z0-9_.-]+$'
    $isApi = $url -ceq $releaseApi
    if (-not (Test-Endpoint $url $false $url)) { throw 'untrusted_url' }
    if (-not $isApi -and ($u.Host -ne 'github.com' -or $u.Query -or $u.AbsolutePath -cnotmatch $assetPattern)) { throw 'untrusted_url' }
    if ($isApi -and $request.output_path) { throw 'invalid_api_target' }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(900)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('AiGoodBro-Windows-Update')
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    $current = $url
    for ($redirect = 0; $redirect -le 5; $redirect++) {
        $response = $client.GetAsync($current, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) {
            if ($isApi -or $redirect -eq 5 -or -not $response.Headers.Location) { throw 'redirect_rejected' }
            $next = New-Object Uri([Uri]$current, $response.Headers.Location)
            if (-not (Test-Endpoint $next.AbsoluteUri $true $url)) { throw 'redirect_rejected' }
            $current = $next.AbsoluteUri
            $response.Dispose(); $response = $null
            continue
        }
        if (-not $response.IsSuccessStatusCode) { throw 'http_failed' }
        break
    }
    if ($response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt $limit) { throw 'response_too_large' }
    if ($request.output_path) {
        # Parent creates a unique owned staging directory. Never replace a file.
        $destination = [IO.File]::Open([string]$request.output_path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    } else {
        $destination = New-Object IO.MemoryStream
    }
    $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $buffer = New-Object byte[] 65536
    $received = 0L
    while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $received += $count
        if ($received -gt $limit) { throw 'response_too_large' }
        $destination.Write($buffer, 0, $count)
    }
    $destination.Flush()
    if ($request.output_path) {
        [Console]::Out.Write('{"received":' + $received + '}')
    } else {
        [Console]::Out.Write([Text.Encoding]::UTF8.GetString($destination.ToArray()))
    }
    exit 0
} catch {
    # Never print exception details, signed redirect URLs or private paths.
    [Console]::Error.Write('update_transport_failed')
    exit 1
} finally {
    if ($source) { $source.Dispose() }
    if ($destination) { $destination.Dispose() }
    if ($response) { $response.Dispose() }
    if ($client) { $client.Dispose() }
    if ($handler) { $handler.Dispose() }
}
