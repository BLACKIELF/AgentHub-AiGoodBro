$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$handler.UseDefaultCredentials = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(12)
$cancel = New-Object System.Threading.CancellationTokenSource
$cancel.CancelAfter(12000)
$response = $null
$stream = $null
$body = New-Object System.IO.MemoryStream
try {
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, '__PUBLIC_URL__')
    $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
    if ([int]$response.StatusCode -ne 200) { throw 'Unavailable' }
    if ($response.Content.Headers.ContentLength -gt 1048576) { throw 'Oversized' }
    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $buffer = New-Object byte[] 8192
    while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
        if ($body.Length + $count -gt 1048576) { throw 'Oversized' }
        $body.Write($buffer, 0, $count)
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    [Console]::Write($utf8.GetString($body.ToArray()))
} catch {
    exit 1
} finally {
    if ($stream) { $stream.Dispose() }
    if ($response) { $response.Dispose() }
    $body.Dispose()
    $cancel.Dispose()
    $client.Dispose()
    $handler.Dispose()
}
