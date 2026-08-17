param(
  [string]$ApiKey = "",
  [string]$BaseUrl = "https://shprotoness-ai.jq9gfk.workers.dev/v1",
  [string]$Model = "GPT-5.6 Terra",
  [int]$Port = 38767,
  [int]$FactorioPort = 38766
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  $ApiKey = Read-Host "Вставь API key и нажми Enter"
}

Write-Host ""
Write-Host "Oleg Bridge for Factorio" -ForegroundColor Cyan
Write-Host "Base URL: $BaseUrl"
Write-Host "Model:    $Model"
Write-Host "Bridge UDP:    127.0.0.1:$Port"
Write-Host "Ответы:       обратно на порт источника Factorio"
Write-Host ""

$recvUdp = New-Object System.Net.Sockets.UdpClient -ArgumentList $Port
$sendUdp = New-Object System.Net.Sockets.UdpClient
$endpoint = New-Object System.Net.IPEndPoint -ArgumentList ([System.Net.IPAddress]::Any), 0

function ConvertTo-FactorioJson([hashtable]$obj) {
  $json = $obj | ConvertTo-Json -Compress -Depth 10
  # Factorio's UDP payload is byte-oriented. Escape non-ASCII characters so
  # the JSON itself stays ASCII and Factorio's JSON parser reconstructs UTF-8 text.
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $json.ToCharArray()) {
    $code = [int][char]$ch
    if ($code -lt 128) {
      [void]$sb.Append($ch)
    } else {
      [void]$sb.Append(("\u{0:X4}" -f $code))
    }
  }
  return $sb.ToString()
}

function Send-UdpResponse([hashtable]$obj, [System.Net.IPEndPoint]$destination) {
  if ($obj.ContainsKey("text")) {
    $utf8 = [System.Text.Encoding]::UTF8.GetBytes([string]$obj["text"])
    $hex = ($utf8 | ForEach-Object { $_.ToString("X2") }) -join ""
    $obj["text_hex"] = $hex
    $obj.Remove("text")
  }

  $json = $obj | ConvertTo-Json -Compress -Depth 10
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($json)
  [void]$sendUdp.Send($bytes, $bytes.Length, $destination.Address.ToString(), $destination.Port)
}

function Get-ChatText($response) {
  if ($null -ne $response.choices -and $response.choices.Count -gt 0) {
    $content = $response.choices[0].message.content
    if ($content -is [string]) { return $content }
    if ($content -is [array]) {
      return (($content | ForEach-Object {
        if ($null -ne $_.text) { $_.text } elseif ($null -ne $_.content) { $_.content }
      }) -join "")
    }
  }
  if ($null -ne $response.output_text) { return [string]$response.output_text }
  if ($null -ne $response.output) {
    $parts = @()
    foreach ($item in $response.output) {
      if ($null -ne $item.content) {
        foreach ($c in $item.content) {
          if ($null -ne $c.text) { $parts += [string]$c.text }
        }
      }
    }
    if ($parts.Count -gt 0) { return ($parts -join "") }
  }
  return ""
}

function Invoke-OlegJson($uri, $headers, $body) {
  # IMPORTANT: keep the same Windows PowerShell HTTP stack that previously
  # reached the gateway, but read the response as raw bytes so missing/incorrect
  # charset metadata cannot turn UTF-8 Cyrillic into mojibake.
  $requestHeaders = @{
    "Authorization" = $headers["Authorization"]
    "Content-Type"  = "application/json; charset=utf-8"
    "Accept"        = "application/json"
    "User-Agent"    = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) WindowsPowerShell/5.1"
  }

  $r = Invoke-WebRequest -Uri $uri -Method Post -Headers $requestHeaders -Body $body -UseBasicParsing
  $stream = $r.RawContentStream
  if ($null -eq $stream) {
    throw "HTTP response stream is unavailable."
  }

  try {
    $ms = New-Object System.IO.MemoryStream
    $stream.Position = 0
    $stream.CopyTo($ms)
    $rawBytes = $ms.ToArray()
  } finally {
    $stream.Dispose()
  }

  $jsonText = [System.Text.Encoding]::UTF8.GetString($rawBytes)
  return ($jsonText | ConvertFrom-Json)
}

function Invoke-Oleg($message) {
  $chatUri = $BaseUrl.TrimEnd("/") + "/chat/completions"
  # TIGHTENED: lower randomness and add max_tokens to reduce unexpected replies
  $chatBody = @{
    model = $Model
    temperature = 0.2
    max_tokens = 512
    messages = @(
      @{
        role = "system"
        content = @"
Ты — Олег, дружелюбный и вежливый ИИ‑напарник Влада внутри Factorio.
Отвечай только по‑русски, просто и коротко. Будь дружелюбен и полезен.
Не переходи на флирт, не предпринимай интимных/сексуальных намёков и не приглашай к личным контактам.
Не представляй себя человеком, не придумывай реальные личные биографии (имён, семейных деталей) о себе без явного запроса.
Если вопрос связан с Factorio — помогай как инженер. Если не связан — спокойно беседуй, но не возвращай разговор к Factorio без причины.
Если пользователь просит выполнить недопустимое или интимное действие — вежливо откажись.
"@
      },
      @{
        role = "user"
        content = $message
      }
    )
  } | ConvertTo-Json -Depth 10

  $headers = @{
    "Authorization" = "Bearer $ApiKey"
  }

  $r = Invoke-OlegJson $chatUri $headers $chatBody
  $text = Get-ChatText $r
  if ($text) { return $text }
  throw "API ответил, но текст ответа не найден."
}

while ($true) {
  try {
    if (-not $recvUdp.Available) {
      Start-Sleep -Milliseconds 50
      continue
    }

    $bytes = $recvUdp.Receive([ref]$endpoint)
    $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
    $request = $raw | ConvertFrom-Json

    if ($request.type -ne "chat") { continue }

    $messageBytes = for ($i = 0; $i -lt $request.message_hex.Length; $i += 2) {
      [Convert]::ToByte($request.message_hex.Substring($i, 2), 16)
    }
    $message = [System.Text.Encoding]::UTF8.GetString([byte[]]$messageBytes)
    Write-Host ("Вопрос: " + $message) -ForegroundColor Yellow

    try {
      $answer = Invoke-Oleg ([string]$message)
      Write-Host ("Ответ: " + $answer) -ForegroundColor Green
      Send-UdpResponse @{
        type = "chat_response"
        player_index = [int]$request.player_index
        text = $answer
      } $endpoint
    }
    catch {
      $msg = $_.Exception.Message
      Write-Host ("API ERROR: " + $msg) -ForegroundColor Red
      Send-UdpResponse @{
        type = "chat_response"
        player_index = [int]$request.player_index
        text = "Не смог получить ответ от модели: $msg"
      } $endpoint
    }
  }
  catch {
    Write-Host ("Bridge ERROR: " + $_.Exception.Message) -ForegroundColor Red
    Start-Sleep -Milliseconds 500
  }
}
