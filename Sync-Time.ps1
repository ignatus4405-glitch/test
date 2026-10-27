#Requires -Version 5.1
<#
.SYNOPSIS
    Настраивает службу времени Windows для синхронизации с NTP-серверами.
.DESCRIPTION
    Запускает службу W32Time, сохраняет список NTP-серверов и выполняет
    синхронизацию. На доменных компьютерах требуется явное разрешение.
.PARAMETER NtpServers
    Имена или IP-адреса NTP-серверов, каждый элемент без флагов и запятых.
.PARAMETER AllowDomainJoined
    Разрешает замену доменной иерархии времени на указанные NTP-серверы.
.PARAMETER MarkReliable
    Объявляет контроллер домена надёжным источником времени. Используйте
    только на PDC-эмуляторе корневого домена леса Active Directory.
.EXAMPLE
    .\Sync-Time.ps1
.EXAMPLE
    .\Sync-Time.ps1 -NtpServers 'time.cloudflare.com','time.google.com','time.windows.com'
.EXAMPLE
    .\Sync-Time.ps1 -AllowDomainJoined -MarkReliable
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string[]]$NtpServers = @(
        '0.pool.ntp.org',
        '1.pool.ntp.org',
        '2.pool.ntp.org',
        '3.pool.ntp.org'
    ),

    [switch]$AllowDomainJoined,

    [switch]$MarkReliable
)

$ErrorActionPreference = 'Stop'
# В PowerShell 7 коды возврата w32tm обрабатываются вручную, в том числе для повторных попыток.
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-W32tm {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & $script:W32tmPath @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "w32tm $($Arguments -join ' ') завершился с кодом $code."
    }
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Скрипт предназначен только для Windows.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Запустите PowerShell от имени администратора.'
    }

    foreach ($server in $NtpServers) {
        if ([string]::IsNullOrWhiteSpace($server) -or $server -match '[\s,"]') {
            throw 'Передайте каждый NTP-сервер отдельно: имя или IP-адрес без пробелов, запятых и флагов.'
        }
    }

    # Sysnative позволяет 32-разрядному PowerShell запустить 64-разрядный w32tm.
    $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        'Sysnative'
    } else {
        'System32'
    }
    $script:W32tmPath = Join-Path $env:WINDIR "$systemDirectory\w32tm.exe"
    if (-not (Test-Path -LiteralPath $script:W32tmPath -PathType Leaf)) {
        throw "Не найден системный инструмент w32tm.exe: $script:W32tmPath"
    }

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($null -eq $computer -or $null -eq $computer.PartOfDomain) {
        throw 'Не удалось определить, состоит ли сервер в домене. Настройки не изменены.'
    }
    if ($computer.PartOfDomain -and -not $AllowDomainJoined) {
        throw 'Сервер состоит в домене. Время обычно синхронизируется по иерархии AD. Для намеренного изменения используйте -AllowDomainJoined; см. README.md.'
    }
    if ($MarkReliable -and (-not $computer.PartOfDomain -or $computer.DomainRole -ne 5)) {
        throw '-MarkReliable допустим только на PDC-эмуляторе. Убедитесь также, что это PDC корневого домена леса.'
    }
    if ($computer.PartOfDomain) {
        Write-Warning 'Будет заменена доменная иерархия синхронизации. Проверьте роль сервера и групповые политики AD.'
    }

    # Флаг 0x8 заставляет W32Time использовать NTP client mode.
    $peerList = ($NtpServers | ForEach-Object { "$_,0x8" }) -join ' '
    $configArguments = @('/config', "/manualpeerlist:$peerList", '/syncfromflags:manual')
    if ($MarkReliable) {
        $configArguments += '/reliable:yes'
    }
    $configArguments += '/update'

    Write-Host 'Настройка и запуск службы W32Time...'
    Set-Service -Name W32Time -StartupType Automatic
    Start-Service -Name W32Time
    Invoke-W32tm -Arguments $configArguments

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Host "Синхронизация (попытка $attempt из 3)..."
            $resyncArguments = @('/resync')
            if ($attempt -eq 1) {
                $resyncArguments += '/rediscover'
            }
            Invoke-W32tm -Arguments $resyncArguments
            break
        } catch {
            if ($attempt -eq 3) {
                throw "Настройки сохранены, но синхронизация не выполнена. Проверьте DNS, NTP-серверы и UDP/123. $($_.Exception.Message)"
            }
            Write-Warning "Не удалось синхронизировать время: $($_.Exception.Message) Повтор через 5 секунд."
            Start-Sleep -Seconds 5
        }
    }

    Write-Host "`nТекущий источник времени:"
    Invoke-W32tm -Arguments @('/query', '/source')
    Write-Host "`nСостояние службы времени:"
    Invoke-W32tm -Arguments @('/query', '/status')
} catch {
    Write-Error "Ошибка: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
