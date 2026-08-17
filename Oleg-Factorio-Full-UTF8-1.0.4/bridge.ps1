param(
  [string]$ApiKey = "",
  [string]$ApiUrl = "https://shprotoness-ai.jq9gfk.workers.dev/v1/chat/completions",
  [string]$Model = "GPT-5.6 Terra",
  [int]$BridgePort = 38767
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
  [System.Text.Encoding]::UTF8.GetString([byte[]]$bytes)
}

function ConvertTo-HexUtf8([string]$Text) {
  ([System.Text.Encoding]::UTF8.GetBytes($Text) | ForEach-Object { $_.ToString("X2") }) -join ""
}

function Get-ChatText($Response) {
  if ($Response.choices -and $Response.choices.Count -gt 0 -and $Response.choices[0].message.content -is [string]) {
    return [string]$Response.choices[0].message.content
  }
  throw "API response contains no text."
}

function Invoke-Oleg([string]$Message) {
  $headers = @{
    Authorization = "Bearer $ApiKey"
    "Content-Type" = "application/json"
  }
  $body = @{
    model = $Model
    messages = @(
      @{ role = "system"; content = "Ты — Олег, дружелюбный ИИ-напарник. Общайся по-русски кратко и естественно. На вопросы о Factorio помогай как инженер. Пока у тебя нет состояния игры и игровых инструментов, не утверждай, что видишь фабрику или что-то построил." },
      @{ role = "user"; content = $Message }
    )
  } | ConvertTo-Json -Depth 6
  # Keep the request profile that the gateway already accepted successfully.
  $httpResponse = Invoke-WebRequest -Uri $ApiUrl -Method Post -Headers $headers -Body $body -UseBasicParsing
  $stream = $httpResponse.RawContentStream
  $buffer = New-Object System.IO.MemoryStream
  try {
    $stream.CopyTo($buffer)
    $responseJson = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
    return Get-ChatText ($responseJson | ConvertFrom-Json)
  } finally {
    $buffer.Dispose()
    $stream.Dispose()
  }
}

$receiver = [System.Net.Sockets.UdpClient]::new($BridgePort)
$sender = [System.Net.Sockets.UdpClient]::new()
$remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)

Write-Host "Oleg Bridge for Factorio" -ForegroundColor Cyan
Write-Host "API:        $ApiUrl"
Write-Host "Model:      $Model"
Write-Host "UDP bridge: 127.0.0.1:$BridgePort"
Write-Host ""

while ($true) {
  try {
    $packetBytes = $receiver.Receive([ref]$remote)
    $packet = ([System.Text.Encoding]::UTF8.GetString($packetBytes) | ConvertFrom-Json)
    if ($packet.type -ne "chat") { continue }

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

    $reply = @{
      type = "chat_response"
      player_index = [int]$packet.player_index
      text_hex = ConvertTo-HexUtf8 $answer
    } | ConvertTo-Json -Compress
    $replyBytes = [System.Text.Encoding]::ASCII.GetBytes($reply)
    [void]$sender.Send($replyBytes, $replyBytes.Length, $remote)
  } catch {
    Write-Host ("Bridge ERROR: " + $_.Exception.Message) -ForegroundColor Red
  }
}
