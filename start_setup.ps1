# OpenWrt Wi-Fi Client Setup Script
# Requires: OpenSSH Client (built-in Windows 10/11)
# powershell.exe -ExecutionPolicy Bypass -File "C:\Users\Admin\Documents\dev\GitHub\TP-Link-Arcer-C5-USB\start_setup3.ps1"

$script:RouterIP = "192.168.2.1"
$script:RouterUser = "root"
$script:SSHTimeout = 10
$script:remoteDir = "/root"
$script:localDir = ".\files"
# Предопределенные списки
$script:presetLists = @{
    "1" = @{
        Name = "Setup files"
        URLs = @(
            "https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup.sh",
            "https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/logging_functions.sh",
            "https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/execution_management_functions.sh",
            "https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/system_verification_functions.sh",
            "https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/opkg_functions.sh",
            "https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb_function.sh",
            "https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb.sh",
            "https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/postboot.sh",
            "https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.sh",
            "https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.conf"
        )
    }
    "2" = @{
        Name = "OpenWrt Packages"
        URLs = @()
    }
    "3" = @{
        Name = "OpenWrt firmware"
        URLs = @(
            "https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/openwrt-24.10.5-93920bfa878c-ramips-mt7620-tplink_archer-c5-v4-squashfs-sysupgrade.bin"
        )
    }
}

# param(
#     [string]$RouterIP = "192.168.2.1",
#     [string]$RouterUser = "root"
# )

function OpenWRT-SysUpgrade {
    $ask = Read-Host "`nDo you want to upgrade firmware? (y/n)"
    if ($ask -eq 'y') {
        $urls = $script:presetLists["3"].URLs
        Write-Host "Selected: $($script:presetLists["2"].Name)" -ForegroundColor Green

    }
}

# Function to request credentials
function Get-WiFiCredentials {
    Write-Host "=== OpenWrt Wi-Fi Client Setup ===" -ForegroundColor Cyan
    Write-Host "Router: $RouterIP" -ForegroundColor Yellow
    
    $wifiSSID = Read-Host "Enter Wi-Fi network name (SSID)"
    $wifiPassword = Read-Host "Enter Wi-Fi password" -AsSecureString
    
    # Convert SecureString to plain text
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($wifiPassword)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    
    return @{
        SSID = $wifiSSID
        Password = $plainPassword
    }
}

# Function to check ssh client
function Test-SSHClient {
    $sshPath = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $sshPath) {
        Write-Host "SSH client not found! Install OpenSSH Client:" -ForegroundColor Red
        Write-Host "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" -ForegroundColor Yellow
        return $false
    }
    return $true
}

# Function to test router connection
function Test-RouterConnection {
    param(
        [string]$IP,
        [string]$User
    )
    
    Write-Host "`nTesting connection to router $IP..." -ForegroundColor Yellow
    
    # Test ping first
    $ping = Test-Connection -ComputerName $IP -Count 2 -Quiet
    if (-not $ping) {
        Write-Host "Router $IP is not responding to ping" -ForegroundColor Red
        return $false
    }
    Write-Host "Router is reachable via ping" -ForegroundColor Green
    
    # Test SSH connection
    Write-Host "Testing SSH connection..." -ForegroundColor Yellow
    # $sshCommand = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$env:TEMP\known_hosts_$([System.Guid]::NewGuid().ToString()) -o ConnectTimeout=5 -o BatchMode=yes $User@$IP 'echo connected' 2>&1"
    $sshCommand = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=5 -o BatchMode=yes $User@$IP 'echo connected' 2>&1"

    try {
        $result = Invoke-Expression $sshCommand
        if ($LASTEXITCODE -eq 0) {
            Write-Host "SSH connection successful" -ForegroundColor Green
            return $true
        } else {
            Write-Host "SSH connection failed" -ForegroundColor Red
            Write-Host "Error: $result" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "SSH connection error: $_" -ForegroundColor Red
        return $false
    }
}

# Function to setup Wi-Fi for scanning
function Setup-WiFiForScanning {
    Write-Host "`nSetting up Wi-Fi for scanning..." -ForegroundColor Yellow
    
    # Check current Wi-Fi status
    $wifiStatus = Invoke-RouterCommand "wifi status 2>/dev/null | grep -q 'up' && echo 'up' || echo 'down'"
    
    if ($wifiStatus -match "down") {
        Write-Host "Wi-Fi is down, starting it..." -ForegroundColor Yellow
        Invoke-RouterCommand "wifi up"
        Start-Sleep -Seconds 3
    }
    
    # Get list of radio interfaces
    $radios = Invoke-RouterCommand "ls /sys/class/ieee80211/ 2>/dev/null"
    
    if (-not $radios) {
        Write-Host "No Wi-Fi radios found, checking UCI configuration..." -ForegroundColor Yellow
        
        # Try to get radios from UCI
        $radios = Invoke-RouterCommand "uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1"
        
        if ($radios) {
            Write-Host "Found radios in config: $radios" -ForegroundColor Green
            
            # Enable radios
            $radios -split "`n" | ForEach-Object {
                if ($_.Trim() -ne "") {
                    Write-Host "Enabling $($_.Trim())..." -ForegroundColor Gray
                    Invoke-RouterCommand "uci set wireless.$($_.Trim()).disabled=0"
                }
            }
            Invoke-RouterCommand "uci commit wireless"
            Invoke-RouterCommand "wifi"
            Start-Sleep -Seconds 3
        }
    }
    
    return $radios
}

# Function to scan available Wi-Fi networks
function Scan-WiFiNetworks {
    Write-Host "`nScanning for available Wi-Fi networks..." -ForegroundColor Cyan
    
    # Setup Wi-Fi first
    Setup-WiFiForScanning
    
    # Try different scanning methods
    $scanMethods = @(
        @{
            Name = "iwinfo radio0"
            Command = "iwinfo radio0 scan 2>/dev/null"
        },
        @{
            Name = "iwinfo radio1"
            Command = "iwinfo radio1 scan 2>/dev/null"
        # },
        # @{
        #     Name = "iw dev wlan0 scan"
        #     Command = "iw dev wlan0 scan 2>/dev/null | grep -E 'SSID:|signal:|freq:|BSS'"
        # },
        # @{
        #     Name = "iw dev wlan1 scan"
        #     Command = "iw dev wlan1 scan 2>/dev/null | grep -E 'SSID:|signal:|freq:|BSS'"
        }
    )
    
    $allNetworks = @()
    
    foreach ($method in $scanMethods) {
        Write-Host "Trying method: $($method.Name)..." -ForegroundColor Gray
        $scanResult = Invoke-RouterCommand $method.Command
        
        if ($scanResult -and $scanResult -notmatch "No such device|command not found") {
            Write-Host "Scan successful with $($method.Name)" -ForegroundColor Green
            
            if ($method.Name -match "iwinfo") {
                $networks = Parse-IwinfoResults -ScanResult $scanResult
            } else {
                $networks = Parse-IwResults -ScanResult $scanResult
            }
            
            $allNetworks += $networks
        }
    }
    
    if ($allNetworks.Count -eq 0) {
        Write-Host "Could not scan networks. Trying to create AP mode for scanning..." -ForegroundColor Yellow
        
        # Try to create temporary AP for scanning
        $apNetworks = Setup-TempAPAndScan
        if ($apNetworks) {
            $allNetworks = $apNetworks
        }
    }
    
    if ($allNetworks.Count -eq 0) {
        Write-Host "`nCould not scan any networks. Please check:" -ForegroundColor Red
        Write-Host "  - Wi-Fi is enabled on router" -ForegroundColor Yellow
        Write-Host "  - Wi-Fi drivers are loaded" -ForegroundColor Yellow
        Write-Host "  - Router supports client mode" -ForegroundColor Yellow
        
        # Show current Wi-Fi status
        $status = Invoke-RouterCommand "wifi status 2>/dev/null"
        if ($status) {
            Write-Host "`nCurrent Wi-Fi status:" -ForegroundColor Cyan
            Write-Host $status -ForegroundColor Gray
        }
        
        return $null
    }
    
    # Remove duplicates by BSSID
    $uniqueNetworks = @{}
    foreach ($network in $allNetworks) {
        if ($network.BSSID -and -not $uniqueNetworks.ContainsKey($network.BSSID)) {
            $uniqueNetworks[$network.BSSID] = $network
        }
    }
    
    # Display networks
    Write-Host "`nAvailable Wi-Fi Networks:" -ForegroundColor Green
    Write-Host "=" * 80
    
    $networkList = $uniqueNetworks.Values | Sort-Object -Property Signal -Descending
    $index = 0
    
    foreach ($network in $networkList) {
        $network.Index = $index
        
        $signalColor = if ($network.Signal -ge -50) { "Green" } 
                      elseif ($network.Signal -ge -60) { "Cyan" }
                      elseif ($network.Signal -ge -70) { "Yellow" }
                      else { "Red" }
        
        $signalBar = if ($network.Signal -ge -50) { "████████ (Excellent)" }
                    elseif ($network.Signal -ge -60) { "███████░ (Good)" }
                    elseif ($network.Signal -ge -70) { "█████░░░ (Fair)" }
                    else { "██░░░░░░ (Poor)" }
        
        Write-Host "[$index] " -NoNewline -ForegroundColor Yellow
        if ([string]::IsNullOrEmpty($network.ESSID)) { 
            Write-Host "[Hidden Network]" -NoNewline -ForegroundColor Gray
        } else {
            Write-Host "$($network.ESSID)" -NoNewline -ForegroundColor White
        }
        Write-Host " (CH $($network.Channel))" -NoNewline -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    Signal: $($network.Signal) dBm " -NoNewline
        Write-Host $signalBar -ForegroundColor $signalColor
        Write-Host "    Encryption: $($network.Encryption)"
        Write-Host "    BSSID: $($network.BSSID)"
        Write-Host "-" * 80
        
        $index++
    }
    
    if ($index -eq 0) {
        Write-Host "No networks found" -ForegroundColor Yellow
        return $null
    }
    
    return $networkList
}

# Helper function to parse iwinfo results
function Parse-IwinfoResults {
    param([string]$ScanResult)
    
    $networks = @()
    $currentNetwork = @{}
    
    $ScanResult -split "`n" | ForEach-Object {
        $line = $_.Trim()
        
        if ($line -match '^ESSID: "(.*)"') {
            if ($currentNetwork.Count -gt 0 -and $currentNetwork.ContainsKey("ESSID")) {
                $networks += $currentNetwork.Clone()
            }
            $currentNetwork = @{
                ESSID = $matches[1]
                Signal = -100
                Channel = "?"
                Encryption = "?"
                BSSID = "?"
            }
        }
        elseif ($line -match "^Signal: (-?\d+) dBm") { 
            $currentNetwork.Signal = [int]$matches[1]
        }
        elseif ($line -match "^Channel: (\d+)") { 
            $currentNetwork.Channel = $matches[1]
        }
        elseif ($line -match "^Encryption: (.+)$") { 
            $enc = $matches[1].Trim()
            if ($enc -match "none|off") { $enc = "Open" }
            $currentNetwork.Encryption = $enc
        }
        elseif ($line -match "^BSSID: ([0-9A-Fa-f:]+)") { 
            $currentNetwork.BSSID = $matches[1]
        }
    }
    
    # Add last network
    if ($currentNetwork.Count -gt 0 -and $currentNetwork.ContainsKey("ESSID")) {
        $networks += $currentNetwork
    }
    
    return $networks
}

# Helper function to parse iw results
function Parse-IwResults {
    param([string]$ScanResult)
    
    $networks = @()
    $currentNetwork = @{}
    
    $ScanResult -split "`n" | ForEach-Object {
        $line = $_.Trim()
        
        if ($line -match '^BSS ([0-9a-f:]+)') {
            if ($currentNetwork.Count -gt 0 -and $currentNetwork.ContainsKey("BSSID")) {
                $networks += $currentNetwork.Clone()
            }
            $currentNetwork = @{
                BSSID = $matches[1]
                ESSID = ""
                Signal = -100
                Channel = "?"
                Encryption = "?"
            }
        }
        elseif ($line -match 'SSID: (.*)') {
            $currentNetwork.ESSID = $matches[1].Trim()
        }
        elseif ($line -match 'signal: (-?\d+\.?\d*) dBm') {
            $currentNetwork.Signal = [math]::Round([double]$matches[1])
        }
        elseif ($line -match 'freq: (\d+)') {
            $freq = [int]$matches[1]
            # Convert frequency to channel (simplified)
            if ($freq -ge 2412 -and $freq -le 2484) {
                $currentNetwork.Channel = [math]::Round(($freq - 2412) / 5 + 1)
            } elseif ($freq -ge 5180 -and $freq -le 5825) {
                $currentNetwork.Channel = [math]::Round(($freq - 5180) / 5 + 36)
            }
        }
    }
    
    # Add last network
    if ($currentNetwork.Count -gt 0 -and $currentNetwork.ContainsKey("BSSID")) {
        $networks += $currentNetwork
    }
    
    return $networks
}

# Helper function to setup temporary AP and scan
function Setup-TempAPAndScan {
    Write-Host "Creating temporary AP for scanning..." -ForegroundColor Yellow
    
    # Backup current config
    Invoke-RouterCommand "cp /etc/config/wireless /tmp/wireless.backup"
    
    # Create temporary AP
    $setupCommand = @"
uci set wireless.radio0.disabled=0
uci set wireless.@wifi-iface[0]=wifi-iface
uci set wireless.@wifi-iface[0].device=radio0
uci set wireless.@wifi-iface[0].mode=ap
uci set wireless.@wifi-iface[0].ssid=TempScan
uci set wireless.@wifi-iface[0].network=lan
uci set wireless.@wifi-iface[0].encryption=none
uci commit wireless
wifi
sleep 3
iwinfo wlan0 scan
"@
    
    $scanResult = Invoke-RouterCommand $setupCommand
    
    # Restore backup
    Invoke-RouterCommand "cp /tmp/wireless.backup /etc/config/wireless"
    Invoke-RouterCommand "wifi"
    
    if ($scanResult) {
        return Parse-IwinfoResults -ScanResult $scanResult
    }
    
    return $null
}

# Function to execute commands on router
function Invoke-RouterCommand {
    param([string]$Command)
    
    # $sshCommand = "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $script:RouterUser@$script:RouterIP `"$Command`" 2>&1"
    $sshCommand = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$env:TEMP\known_hosts_$([System.Guid]::NewGuid().ToString()) -o ConnectTimeout=5 -o BatchMode=yes $script:RouterUserr@$script:RouterIP `"$Command`" 2>&1"
    $sshCommand = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=5 -o BatchMode=yes $script:RouterUserr@$script:RouterIP `"$Command`" 2>&1"
    # Write-Host $sshCommand
    try {
        $result = Invoke-Expression $sshCommand
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 255) {
            return $null
        }
        return $result
    }
    catch {
        return $null
    }
}

# Function to select Wi-Fi band
function Select-WiFiBand {
    Write-Host "`n=== Wi-Fi Band Selection ===" -ForegroundColor Cyan
    
    # Get available radio interfaces
    $radios = Invoke-RouterCommand "uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1"
    
    if (-not $radios) {
        Write-Host "No Wi-Fi radios detected, using default" -ForegroundColor Yellow
        return "radio0"
    }
    
    Write-Host "Available Wi-Fi radios:" -ForegroundColor Green
    $radioList = @()
    $index = 0
    
    $radios -split "`n" | ForEach-Object {
        if ($_.Trim() -ne "") {
            $radioList += $_.Trim()
            $hwmode = Invoke-RouterCommand "uci show wireless.$_.band 2>/dev/null"
            $band = if ($hwmode -match "5g") { "5 GHz" } 
                   elseif ($hwmode -match "2g") { "2.4 GHz" }
                   else { "Unknown" }
            
            Write-Host "[$index] $($_.Trim()) - $band" -ForegroundColor White
            $index++
        }
    }
    
    if ($radioList.Count -eq 1) {
        Write-Host "Using only available radio: $($radioList[0])" -ForegroundColor Yellow
        return $radioList[0]
    }
    
    $selection = Read-Host "`nSelect radio index (0-$($radioList.Count-1))"
    if ($selection -match "^\d+$" -and [int]$selection -lt $radioList.Count) {
        return $radioList[[int]$selection]
    } else {
        Write-Host "Invalid selection, using radio0" -ForegroundColor Yellow
        return "radio0"
    }
}

# NEW FUNCTION: Create WWAN interface
function Create-WWANInterface {
    param(
        [string]$Radio,
        [string]$SSID,
        [string]$Password
    )
    
    Write-Host "`nCreating WWAN interface..." -ForegroundColor Cyan
    
    # Check if wwan interface already exists in network config
    $wanExists = Invoke-RouterCommand "uci get network.wwan 2>/dev/null || echo 'not found'"
    
    if ($wanExists -eq "not found") {
        Write-Host "Creating new WWAN interface in network config..." -ForegroundColor Yellow
        
        # Create WWAN interface
        Invoke-RouterCommand "uci set network.wwan=interface"
        Invoke-RouterCommand "uci set network.wwan.proto='dhcp'"
        
        Write-Host "WWAN interface created" -ForegroundColor Green
    } else {
        Write-Host "WWAN interface already exists, updating..." -ForegroundColor Yellow
        Invoke-RouterCommand "uci set network.wwan.proto='dhcp'"
    }
    
    # Check if wifi-iface exists and update it to use wwan
    $ifaceCount = Invoke-RouterCommand "uci show wireless | grep '=wifi-iface' | wc -l"
    $ifaceIndex = -1
    
    # Look for existing interface with this device
    for ($i = 0; $i -lt [int]$ifaceCount; $i++) {
        $ifaceDevice = Invoke-RouterCommand "uci get wireless.@wifi-iface[$i].device 2>/dev/null"
        if ($ifaceDevice -eq $Radio) {
            $ifaceIndex = $i
            break
        }
    }
    
    if ($ifaceIndex -ge 0) {
        # Update existing interface
        Write-Host "Updating existing Wi-Fi interface for $Radio..." -ForegroundColor Yellow
        Invoke-RouterCommand "uci set wireless.@wifi-iface[$ifaceIndex].mode='sta'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[$ifaceIndex].ssid='$SSID'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[$ifaceIndex].encryption='psk2'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[$ifaceIndex].key='$Password'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[$ifaceIndex].network='wwan'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[$ifaceIndex].device='$Radio'"
    } else {
        # Create new interface
        Write-Host "Creating new Wi-Fi interface for $Radio..." -ForegroundColor Yellow
        Invoke-RouterCommand "uci add wireless wifi-iface"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[-1].device='$Radio'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[-1].mode='sta'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[-1].ssid='$SSID'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[-1].encryption='psk2'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[-1].key='$Password'"
        Invoke-RouterCommand "uci set wireless.@wifi-iface[-1].network='wwan'"
    }
    
    # Commit changes
    Invoke-RouterCommand "uci commit network"
    Invoke-RouterCommand "uci commit wireless"
    
    Write-Host "Wi-Fi interface configured to use WWAN network" -ForegroundColor Green
    
    # Show configuration
    Write-Host "`nCurrent WWAN configuration:" -ForegroundColor Cyan
    $wwanConfig = Invoke-RouterCommand "uci show network.wwan"
    Write-Host $wwanConfig -ForegroundColor Gray
    
    $wifiConfig = Invoke-RouterCommand "uci show wireless.@wifi-iface[-1]"
    Write-Host $wifiConfig -ForegroundColor Gray
}

# NEW FUNCTION: Setup firewall for WWAN
function Setup-FirewallForWWAN {
    Write-Host "`nConfiguring firewall for WWAN..." -ForegroundColor Yellow
    
    # Check if wwan zone exists
    $wwanZone = Invoke-RouterCommand "uci get firewall.@zone[-1].name 2>/dev/null | grep -q 'wwan' && echo 'exists' || echo 'not found'"
    
    if ($wwanZone -eq "not found") {
        # Add WWAN to WAN zone or create new zone
        $wanZoneIndex = -1
        $zoneCount = Invoke-RouterCommand "uci show firewall | grep '=zone' | wc -l"
        
        for ($i = 0; $i -lt [int]$zoneCount; $i++) {
            $zoneName = Invoke-RouterCommand "uci get firewall.@zone[$i].name 2>/dev/null"
            if ($zoneName -eq "wan") {
                $wanZoneIndex = $i
                break
            }
        }
        
        if ($wanZoneIndex -ge 0) {
            # Add wwan to existing WAN zone's network list
            $wanNetworks = Invoke-RouterCommand "uci get firewall.@zone[$wanZoneIndex].network 2>/dev/null"
            if ($wanNetworks -notmatch "wwan") {
                Invoke-RouterCommand "uci add_list firewall.@zone[$wanZoneIndex].network='wwan'"
                Write-Host "Added WWAN to WAN firewall zone" -ForegroundColor Green
            }
        } else {
            # Create new zone for WWAN
            Invoke-RouterCommand "uci add firewall zone"
            Invoke-RouterCommand "uci set firewall.@zone[-1].name='wwan'"
            Invoke-RouterCommand "uci set firewall.@zone[-1].network='wwan'"
            Invoke-RouterCommand "uci set firewall.@zone[-1].input='ACCEPT'"
            Invoke-RouterCommand "uci set firewall.@zone[-1].output='ACCEPT'"
            Invoke-RouterCommand "uci set firewall.@zone[-1].forward='REJECT'"
            Invoke-RouterCommand "uci set firewall.@zone[-1].masq='1'"
            Invoke-RouterCommand "uci set firewall.@zone[-1].mtu_fix='1'"
            Write-Host "Created new WWAN firewall zone" -ForegroundColor Green
        }
    }
    
    # Add forwarding from lan to wwan
    $forwardCount = Invoke-RouterCommand "uci show firewall | grep '=forwarding' | wc -l"
    $forwardExists = $false
    
    for ($i = 0; $i -lt [int]$forwardCount; $i++) {
        $src = Invoke-RouterCommand "uci get firewall.@forwarding[$i].src 2>/dev/null"
        $dest = Invoke-RouterCommand "uci get firewall.@forwarding[$i].dest 2>/dev/null"
        if ($src -eq "lan" -and $dest -eq "wan" -or $src -eq "lan" -and $dest -eq "wwan") {
            $forwardExists = $true
            break
        }
    }
    
    if (-not $forwardExists) {
        Invoke-RouterCommand "uci add firewall forwarding"
        Invoke-RouterCommand "uci set firewall.@forwarding[-1].src='lan'"
        Invoke-RouterCommand "uci set firewall.@forwarding[-1].dest='wan'"
        Write-Host "Added LAN to WAN forwarding rule" -ForegroundColor Green
    }
    
    Invoke-RouterCommand "uci commit firewall"
}

# Function to test WWAN connection
function Test-WWANConnection {
    param([string]$SSID)
    
    Write-Host "`nTesting WWAN connection..." -ForegroundColor Cyan
    
    $maxAttempts = 30
    $attempt = 0
    $connected = $false
    
    while ($attempt -lt $maxAttempts) {
        $attempt++
        Write-Host "." -NoNewline
        
        # ПРОВЕРКА 1: Существует ли сеть wwan в конфигурации
        $networkExists = Invoke-RouterCommand "uci show network.wwan 2>/dev/null | grep -c 'network.wwan' || echo '0'"

        # ПРОВЕРКА 2: Проверка наличия IP через ip addr
        $hasIP = Invoke-RouterCommand "ip addr show | grep -E 'phy[0-9]' | grep 'inet'"

        # ПРОВЕРКА 4: Wi-Fi подключен к указанному SSID
        $wifiStatus = Invoke-RouterCommand "iwinfo | grep -A 5 '$SSID' | grep -E 'connected|Signal|dBm'"

        # Если сеть существует и есть IP через ubus - подключение установлено
        if (-not $networkExists -eq 0 -and -not $hasIP -eq "") {
            $connected = $true
            break
        }
        
        # Альтернативная проверка: ищем любой wlan интерфейс с IP
        if (-not $connected) {
            $wlanWithIP = Invoke-RouterCommand "ip addr show | grep -E 'wlan[0-9]' | grep -q 'inet' && echo 'yes' || echo 'no'"
            if ($wlanWithIP -eq "yes" -and $wifiStatus) {
                $connected = $true
                break
            }
        }
        
        Start-Sleep -Seconds 2
    }
    
    Write-Host ""
    
    if ($connected) {
        Write-Host "WWAN network is configured and has IP address!" -ForegroundColor Green

        Write-Host $hasIP
        Write-Host $wifiStatus

        # Тест интернет соединения
        Write-Host "`nTesting internet connectivity..." -ForegroundColor Yellow
        
        # Пробуем пинг до разных адресов
        $pingGoogle = Invoke-RouterCommand "ping -c 2 -W 2 8.8.8.8 2>/dev/null | grep -q '2 packets received' && echo 'ok' || echo 'failed'"
        $pingYandex = Invoke-RouterCommand "ping -c 2 -W 2 77.88.8.8 2>/dev/null | grep -q '2 packets received' && echo 'ok' || echo 'failed'"
        
        if ($pingGoogle -eq "ok" -or $pingYandex -eq "ok") {
            Write-Host "Internet connectivity confirmed!" -ForegroundColor Green
            
            # Проверяем DNS резолвинг
            $dnsTest = Invoke-RouterCommand "nslookup google.com 2>/dev/null | grep -q 'Address' && echo 'ok' || echo 'failed'"
            if ($dnsTest -eq "ok") {
                Write-Host "DNS resolution working" -ForegroundColor Green
            }
        } else {
            Write-Host "WWAN is up but no internet connectivity" -ForegroundColor Yellow
            
            # Диагностика
            Write-Host "`nDiagnostic information:" -ForegroundColor Yellow
            $routes = Invoke-RouterCommand "ip route show"
            Write-Host "Current routes:" -ForegroundColor Gray
            Write-Host $routes -ForegroundColor Gray
        }
        
    } else {
        Write-Host "WWAN network failed to get IP address" -ForegroundColor Red
        
        # Детальная диагностика проблемы
        Write-Host "`nDiagnostic information:" -ForegroundColor Yellow
        
        # 1. Проверяем конфигурацию network
        $networkConfig = Invoke-RouterCommand "uci show network | grep -E 'network.wwan|network.wan'"
        Write-Host "Network configuration:" -ForegroundColor Gray
        Write-Host $networkConfig -ForegroundColor Gray
        
        # 2. Проверяем конфигурацию wireless
        $wirelessConfig = Invoke-RouterCommand "uci show wireless | grep -E 'device|ssid|network'"
        Write-Host "`nWireless configuration:" -ForegroundColor Gray
        Write-Host $wirelessConfig -ForegroundColor Gray
        
        # 3. Проверяем физические интерфейсы
        $interfaces = Invoke-RouterCommand "ip link show | grep -E 'wlan[0-9]'"
        Write-Host "`nPhysical interfaces:" -ForegroundColor Gray
        Write-Host $interfaces -ForegroundColor Gray
        
        # 4. Проверяем DHCP клиент
        $dhcpLeases = Invoke-RouterCommand "ps | grep dhcp | grep -v grep"
        Write-Host "`nDHCP clients:" -ForegroundColor Gray
        Write-Host $dhcpLeases -ForegroundColor Gray
        
        # 5. Проверяем логи
        $logs = Invoke-RouterCommand "logread | grep -i 'wlan\|dhcp\|wwan' | tail -5"
        Write-Host "`nRecent logs:" -ForegroundColor Gray
        Write-Host $logs -ForegroundColor Gray
    }
    
    # Возвращаем статус для использования в основной функции
    return $connected
}

# Функция для пакетной загрузки
function Batch-DownloadFiles {
    param(
        [string]$RouterIP,
        [string]$RouterUser,
        [string]$NewIP,
        [string]$remoteDir,
        [string]$localDir,
        [string]$presetList
    )
    
    $localDir = $script:localDir

    Write-Host "`n=== Batch File Download ===" -ForegroundColor Cyan
    
    $urls = $script:presetLists["$presetList"].URLs
    # $urls = $presetList
    Write-Host "Selected: $($script:presetLists["$presetList"].Name)" -ForegroundColor Green
    # Write-Host "Selected: $($presetList.Name)" -ForegroundColor Green
    
    if ($urls.Count -eq 0) {
        Write-Host "No URLs to download" -ForegroundColor Yellow
        return $null
    }
    
    Write-Host "`nURLs to download ($($urls.Count) files):" -ForegroundColor Cyan
    for ($i = 0; $i -lt [Math]::Min(5, $urls.Count); $i++) {
        Write-Host "  [$i] $($urls[$i])" -ForegroundColor Gray
    }
    if ($urls.Count -gt 5) {
        Write-Host "  ... and $($urls.Count - 5) more" -ForegroundColor Gray
    }
    
    # Создаем временные директории
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    
    # Write-Host "`nCreating directories..." -ForegroundColor Yellow
    # Write-Host "  Remote: $remoteDir"
    # Write-Host "  Local: $localDir"
    
    # # Создаем remote директорию
    # $mkdirResult = Invoke-RouterCommand "mkdir -p $remoteDir"
    # if (-not $mkdirResult -and $LASTEXITCODE -ne 0) {
    #     Write-Host "Failed to create remote directory" -ForegroundColor Red
    #     return $null
    # }
    
    # $downloadResult = Invoke-RouterCommand "cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup.sh && chmod +x setup.sh && ./setup.sh"
    # Write-Host "`nDownloading: $downloadResult"

    # Скачиваем с индикатором прогресса
    $results = @()
    $total = $urls.Count
    
    for ($i = 0; $i -lt $total; $i++) {
        $url = $urls[$i].Trim()  # Убираем пробелы
        $filename = [System.IO.Path]::GetFileName($url)
        
        # Если имя файла пустое или невалидное, генерируем имя
        if ([string]::IsNullOrEmpty($filename) -or $filename -match '^[0-9a-f]{40}$' -or $filename -match '^[0-9a-f]{64}$') {
            $filename = "file_$(Get-Random -Minimum 1000 -Maximum 9999).bin"
        }
        
        # Очищаем имя файла от недопустимых символов
        $filename = $filename -replace '[<>:"/\\|?*]', '_'
        
        # Показываем прогресс
        $percent = [math]::Round((($i + 1) / $total) * 100, 1)
        Write-Progress -Activity "Downloading files" -Status "$percent% Complete" -CurrentOperation $filename -PercentComplete $percent
        
        Write-Host "`n[$($i+1)/$total] Downloading: $filename" -ForegroundColor Cyan
        
        # Скачиваем на роутер
        $remotePath = "$remoteDir/$filename"
        $LocalPath = "$localDir/$filename"

        # Экранируем URL для безопасной передачи
        $escapedUrl = $url -replace "'", "'\\''"
        $downloadCommand = "wget $url -O $remotePath"
        $downloadResult = Invoke-RouterCommand "cd /root && $downloadCommand"
        # Write-Host $downloadCommand
        Write-Host $downloadResult

        # Проверяем результат скачивания
        $downloadSuccess = $false
        if ($downloadResult -match "saved|100%|connected") {
            $downloadSuccess = $true
        } else {
            # Проверяем размер файла
            $fileSize = Invoke-RouterCommand "wc -c < '$remotePath' 2>/dev/null | tr -d ' '"
            if ($fileSize -and $fileSize -match "^\d+$" -and [int]$fileSize -gt 0) {
                $downloadSuccess = $true
            }
        }
        
        if ($downloadSuccess) {
            Write-Host "  Downloaded to router" -ForegroundColor Green
        } else {
            Write-Host "  Download failed" -ForegroundColor Red
            Write-Host "  Error: $downloadResult" -ForegroundColor Red
            $results += @{
                URL = $url
                Status = "DownloadFailed"
                Error = $downloadResult
            }
            # Создаем локальную директорию
            try {
                New-Item -ItemType Directory -Force -Path $localDir | Out-Null
                Write-Host "Local directory created" -ForegroundColor Green
            } catch {
                Write-Host "Failed to create local directory: $_" -ForegroundColor Red
                return $null
            }

            Download-WithWebRequest $Url $LocalPath
            Copy-FileToRouter -LocalPath $LocalPath -RemotePath $remoteDir #-RouterIP $script:$RouterIP -RouterUser $script:$RouterUser
        }
    }
    
    Write-Progress -Activity "Downloading files" -Completed
    
    # Показываем результаты
    Show-DownloadResults -Results $results -LocalDir $localDir -RemoteDir $remoteDir -RouterUser $RouterUser -RouterIP $targetIP
    
    return $results
}

# Показываем результаты cкачивания
function Show-DownloadResults {
    param(
        $Results,
        [string]$LocalDir,
        [string]$RemoteDir,
        [string]$RouterUser,
        [string]$RouterIP
    )
    
    Write-Host "`n" + "=" * 60 -ForegroundColor Cyan
    Write-Host "DOWNLOAD SUMMARY" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
    
    $success = ($Results | Where-Object { $_.Status -eq "Success" }).Count
    $failed = ($Results | Where-Object { $_.Status -ne "Success" }).Count
    $total = $Results.Count
    
    # Статистика
    Write-Host "`nStatistics:" -ForegroundColor Yellow
    Write-Host "  Total files: $total" -ForegroundColor White
    Write-Host "  Successful: $success" -ForegroundColor $(if ($success -gt 0) { "Green" } else { "Gray" })
    Write-Host "  Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Gray" })
    
    # Директории
    Write-Host "`nDirectories:" -ForegroundColor Yellow
    Write-Host "  Local: $LocalDir" -ForegroundColor White
    Write-Host "  Remote: $RemoteDir" -ForegroundColor White
    
    # Успешные загрузки
    if ($success -gt 0) {
        Write-Host "`nSuccessfully downloaded files:" -ForegroundColor Green
        $successfulFiles = $Results | Where-Object { $_.Status -eq "Success" }
        foreach ($file in $successfulFiles) {
            $fileInfo = Get-Item $file.LocalPath -ErrorAction SilentlyContinue
            if ($fileInfo) {
                $size = if ($fileInfo.Length -gt 1MB) {
                    "{0:N2} MB" -f ($fileInfo.Length / 1MB)
                } elseif ($fileInfo.Length -gt 1KB) {
                    "{0:N2} KB" -f ($fileInfo.Length / 1KB)
                } else {
                    "{0} B" -f $fileInfo.Length
                }
                $fileName = Split-Path $file.LocalPath -Leaf
                Write-Host "  $fileName ($size)" -ForegroundColor White
            } else {
                Write-Host "  $(Split-Path $file.LocalPath -Leaf)" -ForegroundColor White
            }
        }
    }
    
    # Неудачные загрузки
    if ($failed -gt 0) {
        Write-Host "`nFailed downloads:" -ForegroundColor Red
        $failedFiles = $Results | Where-Object { $_.Status -ne "Success" }
        foreach ($file in $failedFiles) {
            Write-Host "  • $($file.URL)" -ForegroundColor Red
            Write-Host "    Status: $($file.Status)" -ForegroundColor Gray
            if ($file.Error) {
                Write-Host "    Error: $($file.Error)" -ForegroundColor Gray
            }
        }
    }
    
    # Создаем лог файл
    $logPath = Join-Path $LocalDir "download_log.txt"
    $logContent = @()
    $logContent += "Download Log - $(Get-Date)"
    $logContent += "=" * 50
    $logContent += "Total files: $total"
    $logContent += "Successful: $success"
    $logContent += "Failed: $failed"
    $logContent += ""
    $logContent += "Files:"
    
    foreach ($result in $Results) {
        if ($result.Status -eq "Success") {
            $logContent += "[OK] $($result.URL) -> $($result.LocalPath)"
        } else {
            $logContent += "[FAIL] $($result.URL) - $($result.Status): $($result.Error)"
        }
    }
    
    # $logContent | Out-File -FilePath $logPath -Encoding UTF8
    # Write-Host "`nLog saved to: $logPath" -ForegroundColor Gray
}

# Функция для копирования файла с Windows на роутер
function Copy-FileToRouter {
    param(
        [string]$LocalPath,           # Путь к файлу на Windows
        [string]$RemotePath,           # Путь на роутере (например, "/root/")
        [string]$RouterIP = $script:RouterIP,
        [string]$RouterUser = $script:RouterUser
    )
    
    Write-Host "`nCopying file to router..." -ForegroundColor Cyan
    
    # Проверяем существование локального файла
    if (-not (Test-Path $LocalPath)) {
        Write-Host "Local file not found: $LocalPath" -ForegroundColor Red
        return $false
    }
    
    # Получаем имя файла
    $fileName = Split-Path $LocalPath -Leaf
    
    # Формируем полный путь назначения
    if ($RemotePath.EndsWith("/")) {
        $fullRemotePath = "$RemotePath$fileName"
    } else {
        $fullRemotePath = "$RemotePath/$fileName"
    }
    
    Write-Host "Copying: $LocalPath -> ${RouterUser}@${RouterIP}:${fullRemotePath}" -ForegroundColor Yellow
    
    # SCP команда для копирования С Windows НА роутер
    $scpCommand = "scp -o StrictHostKeyChecking=no `"$LocalPath`" ${RouterUser}@${RouterIP}:'${fullRemotePath}' 2>&1"
    Write-Host $scpCommand
    try {
        $result = Invoke-Expression $scpCommand
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "File successfully copied to router" -ForegroundColor Green
            
            # Проверяем, что файл скопировался
            $checkCommand = "ls -la '$fullRemotePath' 2>/dev/null"
            $checkResult = Invoke-RouterCommand -Command $checkCommand
            
            if ($checkResult) {
                Write-Host "File on router: $checkResult" -ForegroundColor Gray
                return $true
            }
        } else {
            Write-Host "SCP failed with exit code: $LASTEXITCODE" -ForegroundColor Red
            Write-Host "Error: $result" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
        return $false
    }
}

# Скачивание напрямую с GitHub на Windows
function Download-WithWebRequest {
    param(
        [string]$Url,
        [string]$LocalPath
    )
    
    try {
        Invoke-WebRequest -Uri $Url -OutFile $LocalPath -UserAgent "Mozilla/5.0"
        Write-Host "Downloaded directly to Windows" -ForegroundColor Green
    }
    catch {
        Write-Host "Download failed: $_" -ForegroundColor Red
    }
}

# Main setup function
function Set-OpenWrtWiFiClient {
    # Check SSH
    if (-not (Test-SSHClient)) {
        return
    }
    
    # Test router connection first
    $connectionOk = Test-RouterConnection -IP $script:RouterIP -User $script:RouterUser
    if (-not $connectionOk) {
        Write-Host "`nCannot proceed without router connection!" -ForegroundColor Red
        return
    }
    
    # Try to scan networks
    $networks = Scan-WiFiNetworks
    
    if (-not $networks) {
        Write-Host "`nCannot scan networks. Proceeding with manual entry." -ForegroundColor Yellow
    } else {
        # Ask if user wants to select from scanned networks
        $selectFromScan = Read-Host "`nDo you want to select from scanned networks? (y/n)"
        
        if ($selectFromScan -eq 'y') {
            $selection = Read-Host "Enter network number to connect to"
            if ($selection -match "^\d+$" -and [int]$selection -lt $networks.Count) {
                $selectedNetwork = $networks[[int]$selection]
                $wifiSSID = $selectedNetwork.ESSID
                Write-Host "Selected: $wifiSSID" -ForegroundColor Green
                
                $wifiPassword = Read-Host "Enter Wi-Fi password" -AsSecureString
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($wifiPassword)
                $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                
                $wifi = @{
                    SSID = $wifiSSID
                    Password = $plainPassword
                }
            } else {
                Write-Host "Invalid selection, using manual entry" -ForegroundColor Yellow
                $wifi = Get-WiFiCredentials
            }
        } else {
            $wifi = Get-WiFiCredentials
        }
    }
    
    if (-not $wifi) {
        $wifi = Get-WiFiCredentials
    }
    
    # Select Wi-Fi band
    $selectedRadio = Select-WiFiBand
    
    Write-Host "`nStarting router configuration..." -ForegroundColor Green
    
    # Create backup
    Write-Host "Creating backup..." -ForegroundColor Yellow
    Invoke-RouterCommand "cp /etc/config/wireless /etc/config/wireless.backup"
    Invoke-RouterCommand "cp /etc/config/network /etc/config/network.backup"
    Invoke-RouterCommand "cp /etc/config/firewall /etc/config/firewall.backup"
    
    # Enable the selected radio
    Write-Host "Enabling radio $selectedRadio..." -ForegroundColor Yellow
    Invoke-RouterCommand "uci set wireless.$selectedRadio.disabled=0"
    
    # Create WWAN interface and configure Wi-Fi
    Create-WWANInterface -Radio $selectedRadio -SSID $wifi.SSID -Password $wifi.Password
    
    # Setup firewall
    Setup-FirewallForWWAN
    
    # Apply all changes
    Write-Host "Applying all changes..." -ForegroundColor Yellow
    Invoke-RouterCommand "uci commit"
    Invoke-RouterCommand "/etc/init.d/network restart"
    Invoke-RouterCommand "wifi"
    
    Write-Host "`nRouter restarting network. Waiting for WWAN connection..." -ForegroundColor Cyan
    
    # Test WWAN connection
    $connected = Test-WWANConnection -SSID $wifi.SSID
    
    if ($connected) {
        Write-Host "`nWi-Fi client successfully connected via WWAN!" -ForegroundColor Green
        
        # Get new IP
        # $newIP = Invoke-RouterCommand "ip -4 addr show wwan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1"
        # if ($newIP) {
        #     Write-Host "New router IP address on WWAN: $newIP" -ForegroundColor Cyan
        # }
        
        # Invoke-RouterCommand "cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup.sh && chmod +x setup.sh && ./setup.sh"

        # Show network status
        Write-Host "`nNetwork Status:" -ForegroundColor Green
        $status = Invoke-RouterCommand "ip addr show wwan0 2>/dev/null"
        Write-Host $status -ForegroundColor Gray
        Batch-DownloadFiles -RouterIP $script:RouterIP -remoteDir $script:remoteDir -presetList 1
        $status = Invoke-RouterCommand "chmod +x /root/mount_usb.sh && /root/mount_usb.sh"

        # # Ask to download file
        # $downloadFile = Read-Host "`nDo you want to download a file from GitHub? (y/n)"
        
        # if ($downloadFile -eq 'y') {
        #     $githubUrl = "https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup.sh"
            
        #     try {
        #         Write-Host "Downloading file..." -ForegroundColor Yellow
        #         $filename = [System.IO.Path]::GetFileName($githubUrl)
        #         if ([string]::IsNullOrEmpty($filename)) {
        #             $filename = "downloaded_file"
        #         }
                
        #         $downloadCommand = "wget --no-check-certificate -O /root/$filename '$githubUrl' 2>&1"
        #         $downloadResult = Invoke-RouterCommand $downloadCommand
                
        #         if ($LASTEXITCODE -eq 0) {
        #             Write-Host "File downloaded to router" -ForegroundColor Green
        #             Batch-DownloadFiles
        #             Invoke-RouterCommand "chmod +x /root/setup.sh && /root/setup.sh"

        #             # $localPath = Read-Host "Enter path to save file (Enter for current folder)"
        #             # if ([string]::IsNullOrEmpty($localPath)) {
        #             #     $localPath = ".\$filename"
        #             # }
                    
        #             # Write-Host "Copying file..." -ForegroundColor Yellow
        #             # $targetIP = if ($newIP) { $newIP } else { $RouterIP }
        #             # $scpCommand = "scp -o StrictHostKeyChecking=no ${RouterUser}@${targetIP}:/tmp/$filename `"$localPath`""
        #             # Invoke-Expression $scpCommand 2>&1 | Out-Null
                    
        #             # if (Test-Path $localPath) {
        #             #     Write-Host "File saved as: $localPath" -ForegroundColor Green
                        
        #             #     # Clean up
        #             #     Invoke-RouterCommand "rm /tmp/$filename"
        #             # }
        #         } else {
        #             Write-Host "Error downloading file" -ForegroundColor Red
        #         }
        #     }
        #     catch {
        #         Write-Host "Download error: $_" -ForegroundColor Red
        #     }
        # }
    } else {
        Write-Host "`nFailed to connect to Wi-Fi via WWAN" -ForegroundColor Red
        Write-Host "Restoring configuration..." -ForegroundColor Yellow
        Invoke-RouterCommand "cp /etc/config/wireless.backup /etc/config/wireless"
        Invoke-RouterCommand "cp /etc/config/network.backup /etc/config/network"
        Invoke-RouterCommand "cp /etc/config/firewall.backup /etc/config/firewall"
        Invoke-RouterCommand "/etc/init.d/network restart"
        Invoke-RouterCommand "wifi"
        Write-Host "Configuration restored" -ForegroundColor Green
    }
    
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Test-RouterConnection -IP $RouterIP -User $RouterUser

$status = Invoke-RouterCommand "[ -b /dev/sda ] || echo 'USB-drive not found on router'"
Write-Host $status
# Batch-DownloadFiles -RouterIP $script:RouterIP -remoteDir $script:remoteDir -presetList 1
# Batch-DownloadFiles
# exit
# Run main script
Set-OpenWrtWiFiClient