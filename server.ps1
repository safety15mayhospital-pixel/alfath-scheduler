# ===================================================================
# شركة الفتح للأنظمة الذكية - خادم التشغيل المحلي ونقاط الـ REST API
# Al-Fath Smart Scheduler Ultra-Fast Local Server (TcpListener Powered)
# ===================================================================

$port = 5560
$root = $PSScriptRoot
if (-not $root) { $root = "E:\برامج\AA\مواعيدي" }
$dbPath = Join-Path $root "database.json"

function Get-Database {
    if (-not (Test-Path $dbPath)) {
        return @{
            settings = @{}
            technicians = @()
            clients = @()
            appointments = @()
        }
    }
    $raw = [System.IO.File]::ReadAllText($dbPath, [System.Text.Encoding]::UTF8)
    return $raw | ConvertFrom-Json
}

function Save-Database($dbObj) {
    $json = $dbObj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($dbPath, $json, [System.Text.Encoding]::UTF8)
}

$ipAddress = [System.Net.IPAddress]::Loopback
$listener = New-Object System.Net.Sockets.TcpListener($ipAddress, $port)
$localIP = "172.20.1.2"

try {
    $listener.Start()
    Write-Host "===================================================================" -ForegroundColor Green
    Write-Host "   نظام الفتح الذكي - شركة الفتح للأنظمة الذكية يعمل الآن بنجاح!   " -ForegroundColor Yellow
    Write-Host "   من الكمبيوتر:         http://localhost:$port/                  " -ForegroundColor Cyan
    Write-Host "   من الموبايل (نفس الشبكة): http://${localIP}:$port/             " -ForegroundColor Green
    Write-Host "   صفحة حجز العملاء:     http://${localIP}:$port/book             " -ForegroundColor Magenta
    Write-Host "===================================================================" -ForegroundColor Green

    try {
        if ([Environment]::UserInteractive) {
            Start-Process "http://localhost:$port/"
        }
    } catch {}

    while ($true) {
        $client = $null
        try {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            
            # قراءة الطلب
            $buffer = New-Object byte[] 65536
            $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) {
                if ($client) { $client.Close() }
                continue
            }

        $requestText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)
        $lines = $requestText -split "`r`n"
        $firstLine = $lines[0] -split " "
        $method = $firstLine[0]
        $urlWithQuery = if ($firstLine.Length -gt 1) { $firstLine[1] } else { "/" }
        $urlParts = $urlWithQuery -split "\?"
        $urlPath = $urlParts[0]

        # استخراج الـ Body للـ POST / PUT
        $reqBody = ""
        $bodyIdx = $requestText.IndexOf("`r`n`r`n")
        if ($bodyIdx -ge 0) {
            $reqBody = $requestText.Substring($bodyIdx + 4)
        }

        # الرد الافتراضي
        $statusCode = 200
        $statusMsg = "OK"
        $contentType = "application/json; charset=utf-8"
        $responseBytes = [byte[]]@()

        # معالجة OPTIONS لـ CORS
        if ($method -eq "OPTIONS") {
            $headers = "HTTP/1.1 200 OK`r`n" +
                       "Access-Control-Allow-Origin: *`r`n" +
                       "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`r`n" +
                       "Access-Control-Allow-Headers: Content-Type, Authorization`r`n" +
                       "Content-Length: 0`r`n`r`n"
            $hBytes = [System.Text.Encoding]::UTF8.GetBytes($headers)
            $stream.Write($hBytes, 0, $hBytes.Length)
            $client.Close()
            continue
        }

        # -------------------------------------------------------------
        # 1. API: /api/settings
        # -------------------------------------------------------------
        if ($urlPath -eq '/api/settings') {
            $db = Get-Database
            if ($method -eq 'GET') {
                $jsonStr = $db.settings | ConvertTo-Json -Depth 10
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            }
            elseif ($method -eq 'POST') {
                $newSettings = $reqBody | ConvertFrom-Json
                foreach ($prop in $newSettings.PSObject.Properties) {
                    $db.settings | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
                }
                Save-Database $db
                $jsonStr = $db.settings | ConvertTo-Json -Depth 10
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            }
        }

        # -------------------------------------------------------------
        # 2. API: /api/appointments
        # -------------------------------------------------------------
        elseif ($urlPath -eq '/api/appointments') {
            $db = Get-Database
            if ($method -eq 'GET') {
                $jsonStr = $db.appointments | ConvertTo-Json -Depth 10
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            }
            elseif ($method -eq 'POST') {
                $newApt = $reqBody | ConvertFrom-Json
                if (-not $newApt.id) {
                    $newApt | Add-Member -MemberType NoteProperty -Name "id" -Value ("apt_" + [Guid]::NewGuid().ToString().Substring(0,8)) -Force
                }
                if (-not $newApt.created_at) {
                    $newApt | Add-Member -MemberType NoteProperty -Name "created_at" -Value ((Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")) -Force
                }
                
                if ($newApt.client_name -and $newApt.phone) {
                    $existingClient = $db.clients | Where-Object { $_.phone -eq $newApt.phone }
                    if (-not $existingClient) {
                        $newClient = [PSCustomObject]@{
                            id = "c_" + [Guid]::NewGuid().ToString().Substring(0,8)
                            name = $newApt.client_name
                            phone = $newApt.phone
                            area = $newApt.area
                            address = $newApt.address
                            notes = $newApt.notes
                            created_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                        }
                        $db.clients = @($db.clients) + $newClient
                        $newApt | Add-Member -MemberType NoteProperty -Name "client_id" -Value $newClient.id -Force
                    } else {
                        $newApt | Add-Member -MemberType NoteProperty -Name "client_id" -Value $existingClient.id -Force
                    }
                }

                $db.appointments = @($db.appointments) + $newApt
                Save-Database $db
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes(($newApt | ConvertTo-Json -Depth 10))
            }
            elseif ($method -eq 'PUT') {
                $updatedApt = $reqBody | ConvertFrom-Json
                $aptList = [System.Collections.ArrayList]@($db.appointments)
                $idx = -1
                for ($i = 0; $i -lt $aptList.Count; $i++) {
                    if ($aptList[$i].id -eq $updatedApt.id) {
                        $idx = $i
                        break
                    }
                }
                if ($idx -ge 0) {
                    $aptList[$idx] = $updatedApt
                    $db.appointments = $aptList
                    Save-Database $db
                    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes(($updatedApt | ConvertTo-Json -Depth 10))
                } else {
                    $statusCode = 404
                    $statusMsg = "Not Found"
                    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error": "الموعد غير موجود"}')
                }
            }
            elseif ($method -eq 'DELETE') {
                $parsed = $reqBody | ConvertFrom-Json
                $targetId = if ($parsed.id) { $parsed.id } else { "" }
                $db.appointments = @($db.appointments | Where-Object { $_.id -ne $targetId })
                Save-Database $db
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes('{"success": true}')
            }
        }
        elseif ($urlPath -eq '/api/appointments/clear') {
            $db = Get-Database
            $db.appointments = @()
            Save-Database $db
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes('{"success": true, "count": 0}')
        }
        elseif ($urlPath -eq '/api/data/clear') {
            $db = Get-Database
            $db.appointments = @()
            $db.clients = @()
            $db.settings.emergency_closed_date = ""
            Save-Database $db
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes('{"success": true, "message": "All data cleared"}')
        }

        # -------------------------------------------------------------
        # 3. API: /api/clients
        # -------------------------------------------------------------
        elseif ($urlPath -eq '/api/clients') {
            $db = Get-Database
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes(($db.clients | ConvertTo-Json -Depth 10))
        }
        elseif ($urlPath -eq '/api/clients/bulk' -and $method -eq 'POST') {
            $db = Get-Database
            $reqData = $reqBody | ConvertFrom-Json
            $newClients = $reqData.clients
            $addedCount = 0
            $clientList = [System.Collections.ArrayList]@($db.clients)
            foreach ($c in $newClients) {
                if ($c.phone) {
                    $cPhone = [string]$c.phone
                    $exists = $clientList | Where-Object { $_.phone -eq $cPhone }
                    if (-not $exists) {
                        $clientList.Add([PSCustomObject]@{
                            id = if ($c.id) { $c.id } else { "c_" + [Guid]::NewGuid().ToString().Substring(0,8) }
                            name = if ($c.name) { $c.name } else { "عميل بدون اسم" }
                            phone = $cPhone
                            area = if ($c.area) { $c.area } else { "" }
                            address = if ($c.address) { $c.address } else { "" }
                            notes = if ($c.notes) { $c.notes } else { "تمت المزامنة من جهات الاتصال" }
                            created_at = (Get-Date).ToString("o")
                        }) | Out-Null
                        $addedCount++
                    }
                }
            }
            $db.clients = $clientList
            Save-Database $db
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes(('{"success": true, "added_count": ' + $addedCount + ', "total_clients": ' + $clientList.Count + '}'))
        }

        # -------------------------------------------------------------
        # 4. API: /api/emergency/close-today
        # -------------------------------------------------------------
        elseif ($urlPath -eq '/api/emergency/close-today' -and $method -eq 'POST') {
            $db = Get-Database
            $today = (Get-Date).ToString("yyyy-MM-dd")
            $affectedClients = @()
            $template = $db.settings.whatsapp_templates.emergency
            if (-not $template) {
                $template = "عزيزنا العميل {client_name}، نعتذر بشدة لحدوث ظرف طارئ استوجب تأجيل موعد اليوم. سنتواصل معكم فوراً لتحديد موعد بديل. شركة الفتح للأنظمة الذكية."
            }

            foreach ($apt in $db.appointments) {
                if ($apt.date -eq $today -and $apt.status -ne 'cancelled') {
                    $apt.status = 'postponed'
                    $apt.priority = 'postponed'
                    
                    $msg = $template.Replace('{client_name}', $apt.client_name).Replace('{time}', $apt.time).Replace('{type}', $apt.type)
                    $affectedClients += [PSCustomObject]@{
                        appointment_id = $apt.id
                        client_name = $apt.client_name
                        phone = $apt.phone
                        time = $apt.time
                        type = $apt.type
                        area = $apt.area
                        suggested_message = $msg
                        whatsapp_link = "https://wa.me/2" + ($apt.phone -replace '[^0-9]', '') + "?text=" + [System.Uri]::EscapeDataString($msg)
                    }
                }
            }

            $db.settings | Add-Member -MemberType NoteProperty -Name "emergency_closed_date" -Value $today -Force
            Save-Database $db

            $result = [PSCustomObject]@{
                success = $true
                date = $today
                affected_count = $affectedClients.Count
                clients = $affectedClients
            }
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Depth 10))
        }

        # -------------------------------------------------------------
        # 5. API: /api/reminders/due
        # -------------------------------------------------------------
        elseif ($urlPath -eq '/api/reminders/due' -and $method -eq 'GET') {
            $db = Get-Database
            $now = Get-Date
            $today = $now.ToString("yyyy-MM-dd")
            $dueReminders = @()

            foreach ($apt in $db.appointments) {
                if ($apt.date -eq $today -and $apt.status -eq 'confirmed') {
                    try {
                        $aptDateTime = [DateTime]::ParseExact(($apt.date + " " + $apt.time), "yyyy-MM-dd HH:mm", $null)
                        $diffMinutes = ($aptDateTime - $now).TotalMinutes
                        
                        $buffer = if ($apt.travel_buffer) { [int]$apt.travel_buffer } else { 45 }
                        $msgTemplate = $db.settings.whatsapp_templates.reminder_2h
                        $msg = $msgTemplate.Replace('{client_name}', $apt.client_name).Replace('{time}', $apt.time).Replace('{type}', $apt.type)

                        if ($diffMinutes -gt 0 -and $diffMinutes -le 150) {
                            $dueReminders += [PSCustomObject]@{
                                appointment_id = $apt.id
                                client_name = $apt.client_name
                                phone = $apt.phone
                                time = $apt.time
                                minutes_remaining = [math]::Round($diffMinutes)
                                travel_buffer = $buffer
                                travel_departure_time = $aptDateTime.AddMinutes(-$buffer).ToString("HH:mm")
                                message = $msg
                                whatsapp_link = "https://wa.me/2" + ($apt.phone -replace '[^0-9]', '') + "?text=" + [System.Uri]::EscapeDataString($msg)
                            }
                        }
                    } catch {}
                }
            }
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes(($dueReminders | ConvertTo-Json -Depth 10))
        }

        # -------------------------------------------------------------
        # 6. API: /api/booking
        # -------------------------------------------------------------
        elseif ($urlPath -eq '/api/booking' -and $method -eq 'POST') {
            $db = Get-Database
            $bookData = $reqBody | ConvertFrom-Json

            if ($db.settings.emergency_closed_date -eq $bookData.date) {
                $statusCode = 400
                $statusMsg = "Bad Request"
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error": "عذراً، هذا اليوم مغلق ولا يقبل حجوزات حالياً"}')
            } else {
                $approvalMode = if ($db.settings.booking_approval_mode) { $db.settings.booking_approval_mode } else { "manual" }
                $initialStatus = if ($approvalMode -eq 'auto') { "confirmed" } else { "pending" }

                $newBooking = [PSCustomObject]@{
                    id = "apt_bk_" + [Guid]::NewGuid().ToString().Substring(0,8)
                    client_id = $null
                    client_name = $bookData.name
                    phone = $bookData.phone
                    type = $bookData.service_type
                    title = "طلب حجز: " + $bookData.service_type + " - " + $bookData.name
                    date = $bookData.date
                    time = $bookData.time
                    duration = 60
                    travel_buffer = if ($db.settings.default_buffer_minutes) { [int]$db.settings.default_buffer_minutes } else { 45 }
                    priority = "normal"
                    status = $initialStatus
                    area = $bookData.area
                    address = $bookData.address
                    map_link = $bookData.map_link
                    fee = "0"
                    notes = $bookData.notes
                    technician_id = 1
                    created_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                }

                $db.appointments = @($db.appointments) + $newBooking
                Save-Database $db

                $respObj = [PSCustomObject]@{
                    success = $true
                    status = $initialStatus
                    message = if ($initialStatus -eq 'confirmed') { "تم تأكيد حجزكم بنجاح وسيتواصل معكم فني الشركة." } else { "تم استلام طلبكم بنجاح وجارٍ مراجعته والتأكيد معكم عبر الواتساب." }
                    booking = $newBooking
                }
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json -Depth 10))
            }
        }

        # -------------------------------------------------------------
        # 7. API: /api/ai/command
        # -------------------------------------------------------------
        elseif ($urlPath -eq '/api/ai/command' -and $method -eq 'POST') {
            $db = Get-Database
            $aiReq = $reqBody | ConvertFrom-Json
            $textPrompt = $aiReq.prompt
            $p = $textPrompt.ToLower()

            $reply = ""
            $actionTaken = $null

            if ($p -match "جدول" -or $p -match "النهاردة" -or $p -match "اليوم" -and ($p -match "لخص" -or $p -match "ايه عندي" -or $p -match "مواعيد")) {
                $today = (Get-Date).ToString("yyyy-MM-dd")
                $todayApts = @($db.appointments | Where-Object { $_.date -eq $today -and $_.status -ne 'cancelled' })
                if ($todayApts.Count -eq 0) {
                    $reply = "يا أستاذ سليمان، جدولك النهاردة فاضي تماماً ومفيش أي مواعيد مسجلة حتى الآن. تحب نسكن موعد من سلة المؤجلات؟"
                } else {
                    $reply = "جدولك النهاردة يا أستاذ سليمان يحتوي على $($todayApts.Count) موعد:`n"
                    foreach ($a in $todayApts) {
                        $reply += "• الساعة $($a.time) - $($a.client_name) ($($a.type)) في $($a.area)`n"
                    }
                }
            }
            elseif ($p -match "رحل" -or $p -match "أجل" -and ($p -match "العصر" -or $p -match "الظهر" -or $p -match "بكرة")) {
                $today = (Get-Date).ToString("yyyy-MM-dd")
                $tomorrow = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")
                $movedCount = 0
                foreach ($a in $db.appointments) {
                    if ($a.date -eq $today -and [string]::Compare($a.time, "14:30") -ge 0) {
                        $a.date = $tomorrow
                        $movedCount++
                    }
                }
                Save-Database $db
                $actionTaken = "reschedule_batch"
                $reply = "تمام يا فندم، تم ترحيل عدد $movedCount مواعيد من بعد العصر اليوم إلى يوم غد بنجاح!"
            }
            elseif ($p -match "احجز" -or $p -match "ضيف" -or $p -match "سجل") {
                $clientName = "عميل جديد"
                if ($textPrompt -match "(لأستاذ|للمهندس|للدكتور|للعميل|أستاذ|مهندس|دكتور)\s+([^\s]+(?:\s+[^\s]+)?)") {
                    $clientName = $Matches[0] -replace '^ل', ''
                }
                
                $area = "القاهرة"
                if ($textPrompt -match "(التجمع|المعادي|الشيخ زايد|أكتوبر|مدينة نصر|الشروق|مصر الجديدة)") {
                    $area = $Matches[0]
                }

                $type = "inspection"
                if ($textPrompt -match "تركيب|كاميرات|كاميرا") { $type = "installation" }
                elseif ($textPrompt -match "صيانة|عطل|مشكلة") { $type = "maintenance" }
                elseif ($textPrompt -match "خاص|سري|مكتبي") { $type = "private" }

                $targetDate = (Get-Date).ToString("yyyy-MM-dd")
                if ($p -match "بكرة|غدا|غداً") {
                    $targetDate = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")
                } elseif ($p -match "بعد بكرة") {
                    $targetDate = (Get-Date).AddDays(2).ToString("yyyy-MM-dd")
                }

                $targetTime = "12:00"
                if ($textPrompt -match "الساعة\s*(\d{1,2})") {
                    $hour = [int]$Matches[1]
                    if ($p -match "العصر" -and $hour -lt 12) { $hour += 12 }
                    elseif ($p -match "المغرب|العشا|بالليل|مساء" -and $hour -lt 12) { $hour += 12 }
                    $targetTime = "{0:D2}:00" -f $hour
                }

                $conflict = $db.appointments | Where-Object { $_.date -eq $targetDate -and $_.time -eq $targetTime -and $_.status -ne 'cancelled' }
                if ($conflict) {
                    $reply = "تنبيه تضارب: يا فندم عندك موعد بالفعل يوم $targetDate الساعة $targetTime مع ($($conflict.client_name)). الأوقات الفاضية المقترحة في نفس اليوم: الساعة 02:00 م أو 06:00 م. تحب نسجله في أي وقت منهم؟"
                } else {
                    $newAiApt = [PSCustomObject]@{
                        id = "apt_ai_" + [Guid]::NewGuid().ToString().Substring(0,8)
                        client_id = $null
                        client_name = $clientName
                        phone = "01000000000"
                        type = $type
                        title = "طلب ذكي: " + $type + " - " + $clientName
                        date = $targetDate
                        time = $targetTime
                        duration = 90
                        travel_buffer = 45
                        priority = "urgent"
                        status = "confirmed"
                        area = $area
                        address = $area
                        map_link = ""
                        fee = "0"
                        notes = "تمت الإضافة عبر المساعد الذكي الصوتي/النصي: " + $textPrompt
                        technician_id = 1
                        created_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                    }
                    $db.appointments = @($db.appointments) + $newAiApt
                    Save-Database $db
                    $actionTaken = "appointment_created"
                    $reply = "عظيم جداً يا فندم! تم حجز موعد ($type) باسم $clientName في $area يوم $targetDate الساعة $targetTime بنجاح وحفظه في جدولك."
                }
            } else {
                $reply = "أهلاً بك يا فندم في المساعد الذكي لشركة الفتح! أنا جاهز لتسجيل المواعيد بصوتك أو كتابة، ترحيل المواعيد، أو فحص التضارب."
            }

            $aiRes = [PSCustomObject]@{
                reply = $reply
                action = $actionTaken
            }
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes(($aiRes | ConvertTo-Json -Depth 10))
        }

        # -------------------------------------------------------------
        # 8. مسار حجز العميل المستقل /book
        # -------------------------------------------------------------
        elseif ($urlPath -eq '/book' -or $urlPath -eq '/book.html') {
            $filePath = Join-Path $root "book.html"
            if (Test-Path $filePath) {
                $responseBytes = [System.IO.File]::ReadAllBytes($filePath)
                $contentType = "text/html; charset=utf-8"
            }
        }

        # -------------------------------------------------------------
        # 9. تقديم الملفات الساكنة (Static Files & PWA)
        # -------------------------------------------------------------
        else {
            $localRel = $urlPath.TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($localRel)) { $localRel = "index.html" }
            $filePath = Join-Path $root $localRel

            if (Test-Path $filePath -PathType Leaf) {
                $responseBytes = [System.IO.File]::ReadAllBytes($filePath)
                $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
                $contentType = switch ($ext) {
                    ".html" { "text/html; charset=utf-8" }
                    ".js"   { "application/javascript; charset=utf-8" }
                    ".json" { "application/json; charset=utf-8" }
                    ".css"  { "text/css; charset=utf-8" }
                    ".svg"  { "image/svg+xml" }
                    ".png"  { "image/png" }
                    ".jpg"  { "image/jpeg" }
                    ".ico"  { "image/x-icon" }
                    default { "application/octet-stream" }
                }
            } else {
                $indexPath = Join-Path $root "index.html"
                if (Test-Path $indexPath) {
                    $responseBytes = [System.IO.File]::ReadAllBytes($indexPath)
                    $contentType = "text/html; charset=utf-8"
                } else {
                    $statusCode = 404
                    $statusMsg = "Not Found"
                    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
                }
            }
        }

        # كتابة رأس واستجابة HTTP
        $resHeader = "HTTP/1.1 $statusCode $statusMsg`r`n" +
                     "Server: Al-Fath-Scheduler/1.0`r`n" +
                     "Content-Type: $contentType`r`n" +
                     "Content-Length: $($responseBytes.Length)`r`n" +
                     "Access-Control-Allow-Origin: *`r`n" +
                     "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`r`n" +
                     "Access-Control-Allow-Headers: Content-Type, Authorization`r`n" +
                     "Connection: close`r`n`r`n"

        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($resHeader)
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        if ($responseBytes.Length -gt 0) {
            $stream.Write($responseBytes, 0, $responseBytes.Length)
        }
        $stream.Flush()
        $stream.Close()
        if ($client) { $client.Close() }
    }
    catch {
        try { if ($client) { $client.Close() } } catch {}
    }
}
finally {
    if ($listener) {
        $listener.Stop()
    }
}
