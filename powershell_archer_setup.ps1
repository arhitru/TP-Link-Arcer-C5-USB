# Запуск - cd downloads; powershell -ExecutionPolicy Bypass -File ".\powershell_archer_setup.ps1"

# Параметры подключения
$sshConfig = @{
    Server = "192.168.1.1"      # IP или hostname сервера
    Username = "root"           # Имя пользователя
    Command = "uname -n"        # Команда для выполнения
}

# Функция для неинтерактивного SSH с автоматическим добавлением хоста
function Invoke-SSHAutoAccept {
    param(
        [string]$Server,
        [string]$Username,
        [string]$Command
    )
    
    # Формируем команду SSH с автоматическим добавлением хоста
    # StrictHostKeyChecking=accept-new автоматически добавляет хост в known_hosts
    $sshCommand = "ssh -o StrictHostKeyChecking=accept-new $Username@$Server `"$Command`""
    
    try {
        Write-Host "Connecting to $Server..." -ForegroundColor Yellow
        $result = Invoke-Expression $sshCommand
        return $result
    }
    catch {
        Write-Error "Error: $_"
        return $null
    }
}

# Выполнение
$result = Invoke-SSHAutoAccept @sshConfig
if ($result) {
    Write-Host "Name: $result" -ForegroundColor Green
}