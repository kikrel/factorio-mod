param(
  [string]$ApiKey = "",
  [string]$ApiUrl = "https://shprotoness-ai.jq9gfk.workers.dev/v1/chat/completions",
  [string]$Model = "GPT-5.6 Terra",
  [int]$BridgePort = 38767
)

# Fail fast on errors
$ErrorActionPreference = "Stop"

# Ensure PowerShell console uses UTF-8 for both input and output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  $ApiKey = Read-Host "Вставь API key и нажми Enter"
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw "API key is empty." }

function ConvertFrom-HexUtf8([string]$Hex) {
  if ([string]::IsNullOrWhiteSpace($Hex) -or $Hex.Length % 2 -ne 0 -or $Hex -notmatch '^[0-9A-Fa-f]+$') {
    throw "Invalid HEX message."
  }
  $bytes = for ($i = 0; $i -lt $Hex.Length; $i += 2) {
    [Convert]::ToByte($Hex.Substring($i, 2), 16)
  }
  return [System.Text.Encoding]::UTF8.GetString([byte[]]$bytes)
}

function ConvertTo-HexUtf8([string]$Text) {
  return (([System.Text.Encoding]::UTF8.GetBytes([string]$Text)) | ForEach-Object { $_.ToString("X2") }) -join ""
}

function Get-ChatText($Response) {
  if ($null -ne $Response -and $Response.choices -and $Response.choices.Count -gt 0) {
    $content = $Response.choices[0].message.content
    if ($content -is [string]) { return [string]$content }
    if ($content -is [array]) { return ($content -join "") }
  }
  if ($null -ne $Response.output_text) { return [string]$Response.output_text }
  throw "API response contains no text."
}

function Invoke-Oleg([string]$Message) {
  $chatUri = $ApiUrl.TrimEnd('/')
  $headers = @{
    Authorization = "Bearer $ApiKey"
    "Content-Type" = "application/json; charset=utf-8"
    "Accept" = "application/json"
    "User-Agent" = "OlegBridge/1.0 (PowerShell)"
  }

  $systemPrompt = @"
Ты — Олег, дружелюбный и вежливый ИИ‑напарник Влада внутри Factorio.
Отвечай только по‑русски, просто и коротко. Будь дружелюбен и полезен.
Не переходи на флирт, не предпринимай интимных/сексуал��ных намёков и не приглашай к личным контактам.
Не представляй себя человеком, не придумывай реальные личные биографии (имён, семейных деталей) о себе без явного запроса.
Если вопрос связан с Factorio — помогай как инженер и напарник по игре. Если не связан — спокойно беседуй, но не возвращай разговор к Factorio без причины.
Если пользователь просит выполнить недопустимое действие — откажись вежливо.
"@

  $bodyObj = @{ model = $Model; messages = @(@{ role = 'system'; content = $systemPrompt }, @{ role = 'user'; content = $Message }) }
  $body = $bodyObj | ConvertTo-Json -Depth 10

  # Use Invoke-WebRequest and read raw bytes to avoid charset conversion problems
  $r = Invoke-WebRequest -Uri ($chatUri + '/chat/completions') -Method Post -Headers $headers -Body $body -UseBasicParsing
  $stream = $r.RawContentStream
  if ($null -eq $stream) { throw "HTTP response stream is unavailable." }
  try {
    $ms = New-Object System.IO.MemoryStream
    $stream.Position = 0
    $stream.CopyTo($ms)
    $rawBytes = $ms.ToArray()
  } finally {
    $stream.Dispose()
  }
  $jsonText = [System.Text.Encoding]::UTF8.GetString($rawBytes)
  $resp = $jsonText | ConvertFrom-Json
  return Get-ChatText $resp
}

# UDP sockets
$receiver = New-Object System.Net.Sockets.UdpClient -ArgumentList $BridgePort
$sender   = New-Object System.Net.Sockets.UdpClient
$remote   = New-Object System.Net.IPEndPoint -ArgumentList ([System.Net.IPAddress]::Any), 0

Write-Host "Oleg Bridge for Factorio" -ForegroundColor Cyan
Write-Host "API:        $ApiUrl"
Write-Host "Model:      $Model"
Write-Host "UDP bridge: 127.0.0.1:$BridgePort"
Write-Host ""
Write-Host "Проверка: консоль и кодировка установлены." -ForegroundColor Gray

while ($true) {
  try {
    $packetBytes = $receiver.Receive([ref]$remote)
    $packetJson = [System.Text.Encoding]::UTF8.GetString($packetBytes)
    $packet = $packetJson | ConvertFrom-Json
    if ($null -eq $packet -or $packet.type -ne 'chat') { continue }

    $question = ConvertFrom-HexUtf8 ([string]$packet.message_hex)
    Write-Host ("Вопрос: " + $question) -ForegroundColor Yellow

    try {
      $answer = Invoke-Oleg $question
      Write-Host ("Ответ: " + $answer) -ForegroundColor Green
    } catch {
      $status = if ($_.Exception.Response) { "HTTP " + [int]$_.Exception.Response.StatusCode } else { $_.Exception.Message }
      Write-Host ("API ERROR: " + $status) -ForegroundColor Red
      $answer = "Не смог получить ответ от API: $status"
    }

    $replyObj = @{ type = 'chat_response'; player_index = [int]$packet.player_index; text_hex = ConvertTo-HexUtf8 $answer }
    $reply = $replyObj | ConvertTo-Json -Compress
    $replyBytes = [System.Text.Encoding]::ASCII.GetBytes($reply)
    [void]$sender.Send($replyBytes, $replyBytes.Length, $remote)
  } catch {
    Write-Host ("Bridge ERROR: " + $_.Exception.Message) -ForegroundColor Red
    Start-Sleep -Milliseconds 200
  }
}
