#Requires -Version 5.1
<#
    WiFi Share - aplikasi hotspot WiFi untuk Windows 10/11
    Menggunakan Windows Mobile Hotspot API (Wi-Fi Direct), bukan hostednetwork
    yang sudah usang. Tidak butuh install apa pun.

    Jalankan lewat WifiShare.bat, atau:
        powershell -ExecutionPolicy Bypass -File WifiShare.ps1
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Start,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# ---------------------------------------------------------------------------
# QR encoder (byte mode, ECC level M, versi 1-10) - implementasi sendiri
# ---------------------------------------------------------------------------
$qrSource = @'
using System;
using System.Collections.Generic;
using System.Text;

public static class WifiQr
{
    public static int LastVersion;
    public static int LastMask;

    private static readonly int[] TotalCodewords = { 0, 26, 44, 70, 100, 134, 172, 196, 242, 292, 346 };

    // {ecPerBlock, group1Blocks, group1Data, group2Blocks, group2Data} untuk ECC level M
    private static readonly int[][] BlocksM = {
        null,
        new int[] { 10, 1, 16, 0, 0 },
        new int[] { 16, 1, 28, 0, 0 },
        new int[] { 26, 1, 44, 0, 0 },
        new int[] { 18, 2, 32, 0, 0 },
        new int[] { 24, 2, 43, 0, 0 },
        new int[] { 16, 4, 27, 0, 0 },
        new int[] { 18, 4, 31, 0, 0 },
        new int[] { 22, 2, 38, 2, 39 },
        new int[] { 22, 3, 36, 2, 37 },
        new int[] { 26, 4, 43, 1, 44 }
    };

    private static readonly int[][] AlignPos = {
        null,
        new int[] { },
        new int[] { 6, 18 },
        new int[] { 6, 22 },
        new int[] { 6, 26 },
        new int[] { 6, 30 },
        new int[] { 6, 34 },
        new int[] { 6, 22, 38 },
        new int[] { 6, 24, 42 },
        new int[] { 6, 26, 46 },
        new int[] { 6, 28, 50 }
    };

    public static bool[,] Encode(string text)
    {
        byte[] data = Encoding.UTF8.GetBytes(text);
        int version = 0;
        for (int v = 1; v <= 10; v++)
        {
            int capacity = DataCodewords(v) * 8;
            int needed = 4 + (v <= 9 ? 8 : 16) + data.Length * 8;
            if (needed <= capacity) { version = v; break; }
        }
        if (version == 0) throw new ArgumentException("Teks terlalu panjang untuk QR code.");
        if (version * 4 + 17 != TotalCodewords.Length * 2 + 5) { /* no-op, keeps table usage explicit */ }

        byte[] dataCodewords = BuildDataCodewords(data, version);
        byte[] finalCodewords = AddEccAndInterleave(dataCodewords, version);
        return BuildMatrix(finalCodewords, version);
    }

    private static int DataCodewords(int version)
    {
        int[] b = BlocksM[version];
        return b[1] * b[2] + b[3] * b[4];
    }

    private static byte[] BuildDataCodewords(byte[] data, int version)
    {
        int totalData = DataCodewords(version);
        int capacityBits = totalData * 8;
        List<bool> bits = new List<bool>();
        AppendBits(bits, 4, 4);
        AppendBits(bits, data.Length, version <= 9 ? 8 : 16);
        foreach (byte b in data) AppendBits(bits, b, 8);
        AppendBits(bits, 0, Math.Min(4, capacityBits - bits.Count));
        while (bits.Count % 8 != 0) bits.Add(false);

        byte[] result = new byte[totalData];
        int filled = bits.Count / 8;
        for (int i = 0; i < filled; i++)
        {
            int value = 0;
            for (int j = 0; j < 8; j++) value = (value << 1) | (bits[i * 8 + j] ? 1 : 0);
            result[i] = (byte)value;
        }
        byte[] pad = new byte[] { 0xEC, 0x11 };
        for (int i = filled; i < totalData; i++) result[i] = pad[(i - filled) % 2];
        return result;
    }

    private static void AppendBits(List<bool> bits, int value, int length)
    {
        for (int i = length - 1; i >= 0; i--) bits.Add(((value >> i) & 1) != 0);
    }

    private static byte[] AddEccAndInterleave(byte[] data, int version)
    {
        int[] b = BlocksM[version];
        int ecLen = b[0], group1 = b[1], data1 = b[2], group2 = b[3], data2 = b[4];
        int numBlocks = group1 + group2;
        byte[] divisor = ReedSolomonDivisor(ecLen);

        List<byte[]> dataBlocks = new List<byte[]>();
        List<byte[]> ecBlocks = new List<byte[]>();
        int offset = 0;
        for (int i = 0; i < numBlocks; i++)
        {
            int len = i < group1 ? data1 : data2;
            byte[] block = new byte[len];
            Array.Copy(data, offset, block, 0, len);
            offset += len;
            dataBlocks.Add(block);
            ecBlocks.Add(ReedSolomonRemainder(block, divisor));
        }

        List<byte> result = new List<byte>();
        int maxData = Math.Max(data1, data2);
        for (int i = 0; i < maxData; i++)
            for (int j = 0; j < numBlocks; j++)
                if (i < dataBlocks[j].Length) result.Add(dataBlocks[j][i]);
        for (int i = 0; i < ecLen; i++)
            for (int j = 0; j < numBlocks; j++)
                result.Add(ecBlocks[j][i]);

        return result.ToArray();
    }

    private static byte GfMul(byte x, byte y)
    {
        int z = 0;
        for (int i = 7; i >= 0; i--)
        {
            z = (z << 1) ^ ((z >> 7) * 0x11D);
            z ^= ((y >> i) & 1) * x;
        }
        return (byte)(z & 0xFF);
    }

    private static byte[] ReedSolomonDivisor(int degree)
    {
        byte[] result = new byte[degree];
        result[degree - 1] = 1;
        int root = 1;
        for (int i = 0; i < degree; i++)
        {
            for (int j = 0; j < result.Length; j++)
            {
                result[j] = GfMul(result[j], (byte)root);
                if (j + 1 < result.Length) result[j] ^= result[j + 1];
            }
            root = GfMul((byte)root, 2);
        }
        return result;
    }

    private static byte[] ReedSolomonRemainder(byte[] data, byte[] divisor)
    {
        byte[] result = new byte[divisor.Length];
        foreach (byte b in data)
        {
            int factor = b ^ result[0];
            Array.Copy(result, 1, result, 0, result.Length - 1);
            result[result.Length - 1] = 0;
            for (int i = 0; i < result.Length; i++)
                result[i] ^= GfMul(divisor[i], (byte)factor);
        }
        return result;
    }

    private static bool[,] BuildMatrix(byte[] codewords, int version)
    {
        int size = version * 4 + 17;
        bool[,] baseModules = new bool[size, size];
        bool[,] isFunction = new bool[size, size];

        for (int i = 0; i < size; i++)
        {
            SetFunction(baseModules, isFunction, i, 6, i % 2 == 0);
            SetFunction(baseModules, isFunction, 6, i, i % 2 == 0);
        }

        DrawFinder(baseModules, isFunction, 3, 3);
        DrawFinder(baseModules, isFunction, size - 4, 3);
        DrawFinder(baseModules, isFunction, 3, size - 4);

        int[] pos = AlignPos[version];
        int count = pos.Length;
        for (int i = 0; i < count; i++)
        {
            for (int j = 0; j < count; j++)
            {
                if ((i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0)) continue;
                DrawAlignment(baseModules, isFunction, pos[i], pos[j]);
            }
        }

        DrawFormatBits(baseModules, isFunction, size, 0);
        DrawVersion(baseModules, isFunction, version);
        DrawCodewords(baseModules, isFunction, codewords);

        int bestMask = 0;
        int bestScore = int.MaxValue;
        bool[,] best = null;

        for (int mask = 0; mask < 8; mask++)
        {
            bool[,] candidate = (bool[,])baseModules.Clone();
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                    if (!isFunction[y, x] && IsMasked(mask, x, y)) candidate[y, x] = !candidate[y, x];
            DrawFormatBits(candidate, isFunction, size, mask);
            int score = Penalty(candidate);
            if (score < bestScore)
            {
                bestScore = score;
                bestMask = mask;
                best = candidate;
            }
        }

        LastVersion = version;
        LastMask = bestMask;
        return best;
    }

    private static void SetFunction(bool[,] modules, bool[,] isFunction, int row, int col, bool dark)
    {
        modules[row, col] = dark;
        isFunction[row, col] = true;
    }

    private static void DrawFinder(bool[,] modules, bool[,] isFunction, int centerX, int centerY)
    {
        int size = modules.GetLength(0);
        for (int dy = -4; dy <= 4; dy++)
        {
            for (int dx = -4; dx <= 4; dx++)
            {
                int dist = Math.Max(Math.Abs(dx), Math.Abs(dy));
                int x = centerX + dx;
                int y = centerY + dy;
                if (x >= 0 && x < size && y >= 0 && y < size)
                    SetFunction(modules, isFunction, y, x, dist != 2 && dist != 4);
            }
        }
    }

    private static void DrawAlignment(bool[,] modules, bool[,] isFunction, int centerX, int centerY)
    {
        for (int dy = -2; dy <= 2; dy++)
            for (int dx = -2; dx <= 2; dx++)
                SetFunction(modules, isFunction, centerY + dy, centerX + dx,
                    Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
    }

    private static void DrawFormatBits(bool[,] modules, bool[,] isFunction, int size, int mask)
    {
        int data = mask; // ECC level M -> bit format 00
        int rem = data;
        for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        int bits = ((data << 10) | rem) ^ 0x5412;

        for (int i = 0; i <= 5; i++) SetFunction(modules, isFunction, i, 8, GetBit(bits, i));
        SetFunction(modules, isFunction, 7, 8, GetBit(bits, 6));
        SetFunction(modules, isFunction, 8, 8, GetBit(bits, 7));
        SetFunction(modules, isFunction, 8, 7, GetBit(bits, 8));
        for (int i = 9; i < 15; i++) SetFunction(modules, isFunction, 8, 14 - i, GetBit(bits, i));

        for (int i = 0; i < 8; i++) SetFunction(modules, isFunction, 8, size - 1 - i, GetBit(bits, i));
        for (int i = 8; i < 15; i++) SetFunction(modules, isFunction, size - 15 + i, 8, GetBit(bits, i));
        SetFunction(modules, isFunction, size - 8, 8, true);
    }

    private static void DrawVersion(bool[,] modules, bool[,] isFunction, int version)
    {
        if (version < 7) return;
        int size = modules.GetLength(0);
        int rem = version;
        for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        int bits = (version << 12) | rem;
        for (int i = 0; i < 18; i++)
        {
            bool bit = GetBit(bits, i);
            int a = size - 11 + i % 3;
            int b = i / 3;
            SetFunction(modules, isFunction, b, a, bit);
            SetFunction(modules, isFunction, a, b, bit);
        }
    }

    private static void DrawCodewords(bool[,] modules, bool[,] isFunction, byte[] data)
    {
        int size = modules.GetLength(0);
        int bitIndex = 0;
        int totalBits = data.Length * 8;
        for (int right = size - 1; right >= 1; right -= 2)
        {
            if (right == 6) right = 5;
            for (int vert = 0; vert < size; vert++)
            {
                for (int j = 0; j < 2; j++)
                {
                    int x = right - j;
                    bool upward = ((right + 1) & 2) == 0;
                    int y = upward ? size - 1 - vert : vert;
                    if (!isFunction[y, x] && bitIndex < totalBits)
                    {
                        modules[y, x] = ((data[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1) != 0;
                        bitIndex++;
                    }
                }
            }
        }
    }

    private static bool IsMasked(int mask, int x, int y)
    {
        switch (mask)
        {
            case 0: return (x + y) % 2 == 0;
            case 1: return y % 2 == 0;
            case 2: return x % 3 == 0;
            case 3: return (x + y) % 3 == 0;
            case 4: return (x / 3 + y / 2) % 2 == 0;
            case 5: return (x * y) % 2 + (x * y) % 3 == 0;
            case 6: return ((x * y) % 2 + (x * y) % 3) % 2 == 0;
            case 7: return ((x + y) % 2 + (x * y) % 3) % 2 == 0;
        }
        return false;
    }

    private static int Penalty(bool[,] modules)
    {
        int size = modules.GetLength(0);
        int score = 0;

        for (int y = 0; y < size; y++)
        {
            int run = 1;
            for (int x = 1; x < size; x++)
            {
                if (modules[y, x] == modules[y, x - 1])
                {
                    run++;
                    if (run == 5) score += 3;
                    else if (run > 5) score++;
                }
                else run = 1;
            }
        }

        for (int x = 0; x < size; x++)
        {
            int run = 1;
            for (int y = 1; y < size; y++)
            {
                if (modules[y, x] == modules[y - 1, x])
                {
                    run++;
                    if (run == 5) score += 3;
                    else if (run > 5) score++;
                }
                else run = 1;
            }
        }

        for (int y = 0; y < size - 1; y++)
        {
            for (int x = 0; x < size - 1; x++)
            {
                bool color = modules[y, x];
                if (color == modules[y, x + 1] && color == modules[y + 1, x] && color == modules[y + 1, x + 1])
                    score += 3;
            }
        }

        int dark = 0;
        for (int y = 0; y < size; y++)
            for (int x = 0; x < size; x++)
                if (modules[y, x]) dark++;
        int total = size * size;
        score += (Math.Abs(dark * 20 - total * 10) / total) * 10;
        return score;
    }

    private static bool GetBit(int value, int index)
    {
        return ((value >> index) & 1) != 0;
    }
}
'@

Add-Type -TypeDefinition $qrSource -Language CSharp

# ---------------------------------------------------------------------------
# WinRT async helpers
# ---------------------------------------------------------------------------
$script:AsTaskOperation = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

$script:AsTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
    })[0]

function Wait-WinRtOperation {
    param($Operation, [Type]$ResultType)
    try {
        $task = $script:AsTaskOperation.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
        $task.Wait()
        return $task.Result
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        throw $inner.Message
    }
}

function Wait-WinRtAction {
    param($Action)
    try {
        $task = $script:AsTaskAction.Invoke($null, @($Action))
        $task.Wait()
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        throw $inner.Message
    }
}

# ---------------------------------------------------------------------------
# Hotspot wrapper
# ---------------------------------------------------------------------------
function Get-InternetProfile {
    [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]::GetInternetConnectionProfile()
}

function Get-TetheringManager {
    $profile = Get-InternetProfile
    if (-not $profile) { return $null }
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::CreateFromConnectionProfile($profile)
}

function Get-CapabilityText {
    param([int]$Capability)
    switch ($Capability) {
        0 { 'didukung' }
        1 { 'diblokir oleh Group Policy' }
        2 { 'tidak didukung hardware/driver WiFi' }
        3 { 'diblokir oleh operator' }
        4 { 'diblokir oleh edisi Windows (SKU)' }
        5 { 'butuh aplikasi pendukung yang belum terpasang' }
        6 { 'diblokir karena alasan tidak diketahui' }
        7 { 'diblokir oleh kemampuan sistem' }
        default { "kode $Capability" }
    }
}

function Get-HotspotState {
    $mgr = Get-TetheringManager
    if (-not $mgr) { return 'NoInternet' }
    $state = $mgr.TetheringOperationalState
    if ($null -eq $state) { return 'Off' }
    $state.ToString()
}

function Get-HotspotConfig {
    param($Manager)
    if (-not $Manager) { $Manager = Get-TetheringManager }
    if (-not $Manager) { return $null }
    $ap = $Manager.GetCurrentAccessPointConfiguration()
    [pscustomobject]@{
        Ssid     = $ap.Ssid
        Password = $ap.Passphrase
        Band     = $ap.Band.ToString()
    }
}

function Test-HotspotInput {
    param([string]$Ssid, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($Ssid)) { throw 'Nama WiFi (SSID) tidak boleh kosong.' }
    if ($Ssid.Length -gt 32) { throw 'Nama WiFi maksimal 32 karakter.' }
    if ($Password.Length -lt 8 -or $Password.Length -gt 63) { throw 'Password harus 8 sampai 63 karakter.' }
}

function Set-HotspotConfig {
    param(
        [Parameter(Mandatory)] [string]$Ssid,
        [Parameter(Mandatory)] [string]$Password,
        [string]$Band = 'Auto'
    )
    $mgr = Get-TetheringManager
    if (-not $mgr) { throw 'Tidak ada koneksi internet aktif di PC ini.' }

    $type = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
    $config = [Activator]::CreateInstance($type)
    $config.Ssid = $Ssid
    $config.Passphrase = $Password
    $config.AuthenticationKind = [Windows.Networking.NetworkOperators.TetheringWiFiAuthenticationKind, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::Wpa2
    switch ($Band) {
        '2.4 GHz' { $config.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::TwoPointFourGigahertz }
        '5 GHz' { $config.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::FivePointGigahertz }
        default { $config.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::Auto }
    }

    Wait-WinRtAction ($mgr.ConfigureAccessPointAsync($config))
}

function Start-Hotspot {
    $mgr = Get-TetheringManager
    if (-not $mgr) { throw 'Tidak ada koneksi internet aktif di PC ini.' }
    if ([int]$mgr.TetheringCapability -ne 0) {
        throw ('Hotspot tidak bisa diaktifkan: ' + (Get-CapabilityText ([int]$mgr.TetheringCapability)))
    }
    $state = $mgr.TetheringOperationalState
    if ($null -ne $state -and $state.ToString() -eq 'On') { return 'Sudah aktif' }

    $resultType = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
    $result = Wait-WinRtOperation $mgr.StartTetheringAsync() $resultType
    $status = $result.Status.ToString()
    if ($status -ne 'Success' -and $status -ne 'AlreadyOn') {
        $extra = $result.AdditionalErrorMessage
        if ($extra) { throw "Gagal mengaktifkan hotspot: $status ($extra)" }
        throw "Gagal mengaktifkan hotspot: $status"
    }
    'Aktif'
}

function Stop-Hotspot {
    $mgr = Get-TetheringManager
    if (-not $mgr) { throw 'Tidak ada koneksi internet aktif di PC ini.' }
    $state = $mgr.TetheringOperationalState
    if ($null -eq $state -or $state.ToString() -eq 'Off') { return 'Sudah nonaktif' }

    $resultType = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
    $result = Wait-WinRtOperation $mgr.StopTetheringAsync() $resultType
    $status = $result.Status.ToString()
    if ($status -ne 'Success') {
        $extra = $result.AdditionalErrorMessage
        if ($extra) { throw "Gagal mematikan hotspot: $status ($extra)" }
        throw "Gagal mematikan hotspot: $status"
    }
    'Nonaktif'
}

function Apply-HotspotSettings {
    param([string]$Ssid, [string]$Password, [string]$Band = 'Auto', [switch]$KeepRunning)
    Test-HotspotInput -Ssid $Ssid -Password $Password

    $wasOn = (Get-HotspotState) -eq 'On'
    if ($wasOn) { [void](Stop-Hotspot) }
    Set-HotspotConfig -Ssid $Ssid -Password $Password -Band $Band
    if ($wasOn -and $KeepRunning) {
        [void](Start-Hotspot)
        return 'Pengaturan diterapkan, hotspot aktif kembali.'
    }
    if ($wasOn) { return 'Pengaturan diterapkan.' }
    'Pengaturan disimpan.'
}

function Get-ArpTable {
    $map = @{}
    try {
        $lines = & arp -a 2>$null
        foreach ($line in $lines) {
            if ($line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})\s') {
                $map[$matches[2].ToUpperInvariant()] = $matches[1]
            }
        }
    }
    catch { }
    $map
}

function Get-ConnectedDevices {
    $mgr = Get-TetheringManager
    if (-not $mgr) { return @() }
    $st = $mgr.TetheringOperationalState
    if ($null -eq $st -or $st.ToString() -ne 'On') { return @() }

    $arp = Get-ArpTable
    $devices = @()
    foreach ($client in $mgr.GetTetheringClients()) {
        $mac = [string]$client.MacAddress
        $names = @()
        foreach ($hostName in $client.HostNames) {
            if ($hostName.DisplayName) { $names += $hostName.DisplayName }
            elseif ($hostName.CanonicalName) { $names += $hostName.CanonicalName }
        }
        $normalized = $mac.ToUpperInvariant().Replace(':', '-')
        $ip = $arp[$normalized]
        if (-not $ip) { $ip = '-' }
        $label = if ($names.Count -gt 0) { ($names -join ', ') } else { 'Perangkat' }
        $devices += [pscustomobject]@{
            Name = $label
            Mac  = $normalized
            Ip   = $ip
        }
    }
    $devices
}

# ---------------------------------------------------------------------------
# QR helpers
# ---------------------------------------------------------------------------
function Get-WifiQrText {
    param([string]$Ssid, [string]$Password)
    $escape = {
        param([string]$value)
        $value -replace '([\\;,":])', '\$1'
    }
    'WIFI:T:WPA;S:' + (& $escape $Ssid) + ';P:' + (& $escape $Password) + ';;'
}

function New-QrBitmap {
    param([string]$Text, [int]$Scale = 6)
    $matrix = [WifiQr]::Encode($Text)
    $modules = $matrix.GetLength(0)
    $quiet = 4
    $pixels = ($modules + $quiet * 2) * $Scale

    $bitmap = New-Object System.Drawing.Bitmap($pixels, $pixels)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::White)
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(17, 17, 17))
    for ($y = 0; $y -lt $modules; $y++) {
        for ($x = 0; $x -lt $modules; $x++) {
            if ($matrix[$y, $x]) {
                $graphics.FillRectangle($brush, ($x + $quiet) * $Scale, ($y + $quiet) * $Scale, $Scale, $Scale)
            }
        }
    }
    $brush.Dispose()
    $graphics.Dispose()
    $bitmap
}

# ---------------------------------------------------------------------------
# Console modes (dipakai untuk diagnosa / otomasi)
# ---------------------------------------------------------------------------
function Invoke-SelfTest {
    $mgr = Get-TetheringManager
    if (-not $mgr) { Write-Output 'Internet profile: TIDAK ADA'; return }
    $profile = Get-InternetProfile
    Write-Output ('Sumber internet : ' + $profile.ProfileName)
    Write-Output ('Kemampuan       : ' + (Get-CapabilityText ([int]$mgr.TetheringCapability)))
    Write-Output ('Status hotspot  : ' + $mgr.TetheringOperationalState.ToString())
    $cfg = Get-HotspotConfig -Manager $mgr
    Write-Output ('SSID            : ' + $cfg.Ssid)
    Write-Output ('Band            : ' + $cfg.Band)
    Write-Output ('Password        : ' + ('*' * $cfg.Password.Length))

    $qrText = Get-WifiQrText -Ssid $cfg.Ssid -Password $cfg.Password
    $bitmap = New-QrBitmap -Text $qrText -Scale 6
    $outPath = Join-Path $env:TEMP 'wifishare-selftest.png'
    $bitmap.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    Write-Output ('QR versi        : ' + [WifiQr]::LastVersion + ' (mask ' + [WifiQr]::LastMask + ')')
    Write-Output ('QR payload      : ' + $qrText)
    Write-Output ('QR file         : ' + $outPath)
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($Start -or $Stop) {
    try {
        if ($Start) {
            $cfg = Get-HotspotConfig
            if ($cfg) { Test-HotspotInput -Ssid $cfg.Ssid -Password $cfg.Password }
            Write-Output (Start-Hotspot)
        }
        if ($Stop) { Write-Output (Stop-Hotspot) }
    }
    catch {
        Write-Output ('ERROR: ' + $_.Exception.Message)
        exit 1
    }
    return
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
$script:IsBusy = $false
$script:LastQrText = $null
$script:LastStatusText = $null

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'WiFi Share - Hotspot dari PC'
$form.ClientSize = New-Object System.Drawing.Size(760, 660)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Size = 9, [switch]$Bold, [string]$Color)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    if ($Color) { $label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Color) }
    return $label
}

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Location = New-Object System.Drawing.Point(0, 0)
$headerPanel.Size = New-Object System.Drawing.Size(760, 72)
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(23, 37, 63)
$form.Controls.Add($headerPanel)

$lblTitle = New-Label -Text 'WiFi Share' -X 18 -Y 10 -W 240 -H 30 -Size 15 -Bold -Color '#FFFFFF'
$lblTitle.BackColor = [System.Drawing.Color]::Transparent
$headerPanel.Controls.Add($lblTitle)

$lblSource = New-Label -Text 'Sumber internet: -' -X 18 -Y 40 -W 420 -H 22 -Size 9 -Color '#B8C7DE'
$lblSource.BackColor = [System.Drawing.Color]::Transparent
$headerPanel.Controls.Add($lblSource)

$lblStatus = New-Label -Text 'NONAKTIF' -X 520 -Y 16 -W 220 -H 34 -Size 16 -Bold -Color '#F87171'
$lblStatus.BackColor = [System.Drawing.Color]::Transparent
$lblStatus.TextAlign = 'MiddleRight'
$headerPanel.Controls.Add($lblStatus)

$grpConfig = New-Object System.Windows.Forms.GroupBox
$grpConfig.Text = 'Pengaturan Hotspot'
$grpConfig.Location = New-Object System.Drawing.Point(16, 84)
$grpConfig.Size = New-Object System.Drawing.Size(430, 172)
$grpConfig.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($grpConfig)

$grpConfig.Controls.Add((New-Label -Text 'Nama WiFi (SSID)' -X 14 -Y 24 -W 200 -H 20))
$txtSsid = New-Object System.Windows.Forms.TextBox
$txtSsid.Location = New-Object System.Drawing.Point(16, 46)
$txtSsid.Size = New-Object System.Drawing.Size(396, 24)
$txtSsid.MaxLength = 32
$grpConfig.Controls.Add($txtSsid)

$grpConfig.Controls.Add((New-Label -Text 'Password (min. 8 karakter)' -X 14 -Y 78 -W 250 -H 20))
$txtPassword = New-Object System.Windows.Forms.TextBox
$txtPassword.Location = New-Object System.Drawing.Point(16, 100)
$txtPassword.Size = New-Object System.Drawing.Size(300, 24)
$txtPassword.UseSystemPasswordChar = $true
$txtPassword.MaxLength = 63
$grpConfig.Controls.Add($txtPassword)

$chkShow = New-Object System.Windows.Forms.CheckBox
$chkShow.Text = 'Tampilkan'
$chkShow.Location = New-Object System.Drawing.Point(324, 101)
$chkShow.Size = New-Object System.Drawing.Size(90, 22)
$grpConfig.Controls.Add($chkShow)

$grpConfig.Controls.Add((New-Label -Text 'Band' -X 14 -Y 130 -W 60 -H 20))
$cmbBand = New-Object System.Windows.Forms.ComboBox
$cmbBand.Location = New-Object System.Drawing.Point(16, 148)
$cmbBand.Size = New-Object System.Drawing.Size(150, 24)
$cmbBand.DropDownStyle = 'DropDownList'
[void]$cmbBand.Items.AddRange(@('Auto', '2.4 GHz', '5 GHz'))
$cmbBand.SelectedIndex = 0
$grpConfig.Controls.Add($cmbBand)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'Aktifkan Hotspot'
$btnStart.Location = New-Object System.Drawing.Point(16, 268)
$btnStart.Size = New-Object System.Drawing.Size(150, 40)
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.FlatStyle = 'Flat'
$btnStart.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'Matikan'
$btnStop.Location = New-Object System.Drawing.Point(176, 268)
$btnStop.Size = New-Object System.Drawing.Size(110, 40)
$btnStop.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
$btnStop.ForeColor = [System.Drawing.Color]::White
$btnStop.FlatStyle = 'Flat'
$btnStop.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnStop)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = 'Simpan Pengaturan'
$btnApply.Location = New-Object System.Drawing.Point(296, 268)
$btnApply.Size = New-Object System.Drawing.Size(150, 40)
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$btnApply.FlatStyle = 'Flat'
$btnApply.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnApply)

$grpDevices = New-Object System.Windows.Forms.GroupBox
$grpDevices.Text = 'Perangkat Terhubung'
$grpDevices.Location = New-Object System.Drawing.Point(16, 316)
$grpDevices.Size = New-Object System.Drawing.Size(430, 300)
$grpDevices.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($grpDevices)

$listClients = New-Object System.Windows.Forms.ListView
$listClients.Location = New-Object System.Drawing.Point(14, 24)
$listClients.Size = New-Object System.Drawing.Size(400, 228)
$listClients.View = 'Details'
$listClients.FullRowSelect = $true
$listClients.MultiSelect = $false
$listClients.GridLines = $false
$listClients.HeaderStyle = 'Nonclickable'
[void]$listClients.Columns.Add('Nama', 170)
[void]$listClients.Columns.Add('MAC', 130)
[void]$listClients.Columns.Add('IP', 95)
$grpDevices.Controls.Add($listClients)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Muat ulang'
$btnRefresh.Location = New-Object System.Drawing.Point(14, 260)
$btnRefresh.Size = New-Object System.Drawing.Size(120, 28)
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$grpDevices.Controls.Add($btnRefresh)

$lblCount = New-Label -Text '0 / 0 perangkat' -X 146 -Y 266 -W 250 -H 20 -Color '#475569'
$grpDevices.Controls.Add($lblCount)

$grpQr = New-Object System.Windows.Forms.GroupBox
$grpQr.Text = 'Scan untuk konek'
$grpQr.Location = New-Object System.Drawing.Point(460, 84)
$grpQr.Size = New-Object System.Drawing.Size(284, 532)
$grpQr.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($grpQr)

$picQr = New-Object System.Windows.Forms.PictureBox
$picQr.Location = New-Object System.Drawing.Point(16, 26)
$picQr.Size = New-Object System.Drawing.Size(252, 252)
$picQr.SizeMode = 'Zoom'
$picQr.BackColor = [System.Drawing.Color]::White
$picQr.BorderStyle = 'FixedSingle'
$grpQr.Controls.Add($picQr)

$lblQrSsid = New-Label -Text 'SSID: -' -X 16 -Y 292 -W 252 -H 24 -Bold
$grpQr.Controls.Add($lblQrSsid)

$lblQrPass = New-Label -Text 'Password: -' -X 16 -Y 320 -W 252 -H 24
$grpQr.Controls.Add($lblQrPass)

$lblQrHint = New-Label -Text 'Scan QR ini dari kamera HP untuk langsung tersambung ke WiFi PC ini.' -X 16 -Y 356 -W 252 -H 60 -Color '#64748B'
$grpQr.Controls.Add($lblQrHint)

$lblMsg = New-Label -Text '' -X 18 -Y 626 -W 724 -H 22 -Color '#475569'
$form.Controls.Add($lblMsg)

function Set-Message {
    param([string]$Text, [string]$Kind = 'Info')
    $color = switch ($Kind) {
        'Error' { '#B91C1C' }
        'Success' { '#15803D' }
        default { '#475569' }
    }
    $lblMsg.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($color)
    $lblMsg.Text = $Text
}

function Update-QrPreview {
    $ssid = $txtSsid.Text
    $password = $txtPassword.Text
    if ([string]::IsNullOrWhiteSpace($ssid) -or $password.Length -lt 8) {
        $picQr.Image = $null
        $script:LastQrText = $null
        $lblQrSsid.Text = 'SSID: ' + $(if ([string]::IsNullOrWhiteSpace($ssid)) { 'belum diisi' } else { $ssid })
        $lblQrPass.Text = 'Password: ' + $(if ($password.Length -lt 8) { 'min. 8 karakter' } else { $password })
        return
    }
    try {
        $qrText = Get-WifiQrText -Ssid $ssid -Password $password
        if ($qrText -eq $script:LastQrText) { return }
        $old = $picQr.Image
        $picQr.Image = New-QrBitmap -Text $qrText -Scale 6
        if ($old) { $old.Dispose() }
        $script:LastQrText = $qrText
        $lblQrSsid.Text = 'SSID: ' + $ssid
        $lblQrPass.Text = 'Password: ' + $password
    }
    catch {
        $old = $picQr.Image
        $picQr.Image = $null
        if ($old) { $old.Dispose() }
        $script:LastQrText = $null
        $lblQrPass.Text = 'Password/SSID terlalu panjang untuk QR'
    }
}

function Update-Status {
    $mgr = Get-TetheringManager
    if (-not $mgr) {
        if ($script:LastStatusText -ne 'NoInternet') {
            $lblStatus.Text = 'TANPA INTERNET'
            $lblStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#FBBF24')
            $lblSource.Text = 'Sumber internet: tidak ada koneksi aktif'
            $script:LastStatusText = 'NoInternet'
        }
        return
    }

    $profile = Get-InternetProfile
    $lblSource.Text = 'Sumber internet: ' + $profile.ProfileName
    $state = if ($null -eq $mgr.TetheringOperationalState) { 'Off' } else { $mgr.TetheringOperationalState.ToString() }

    if ($state -ne $script:LastStatusText) {
        switch ($state) {
            'On' {
                $lblStatus.Text = 'AKTIF'
                $lblStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#4ADE80')
            }
            'InTransition' {
                $lblStatus.Text = 'MEMPROSES...'
                $lblStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#FBBF24')
            }
            default {
                $lblStatus.Text = 'NONAKTIF'
                $lblStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#F87171')
            }
        }
        $script:LastStatusText = $state
    }

    if ($state -eq 'On') {
        $count = $mgr.ClientCount
        $max = $mgr.MaxClientCount
        $lblCount.Text = "$count / $max perangkat terhubung"
    }
    else {
        $lblCount.Text = '0 / ' + $mgr.MaxClientCount + ' perangkat'
    }
}

function Update-DeviceList {
    $selected = $null
    if ($listClients.SelectedItems.Count -gt 0) { $selected = $listClients.SelectedItems[0].Text }
    $listClients.BeginUpdate()
    $listClients.Items.Clear()
    $devices = @(Get-ConnectedDevices)
    foreach ($device in $devices) {
        $item = New-Object System.Windows.Forms.ListViewItem($device.Name)
        [void]$item.SubItems.Add($device.Mac)
        [void]$item.SubItems.Add($device.Ip)
        [void]$listClients.Items.Add($item)
    }
    $listClients.EndUpdate()
    if ($devices.Count -eq 0) { $lblCount.Text = 'Belum ada perangkat terhubung' }
}

function Set-Busy {
    param([bool]$Busy)
    $script:IsBusy = $Busy
    $btnStart.Enabled = -not $Busy
    $btnStop.Enabled = -not $Busy
    $btnApply.Enabled = -not $Busy
    $txtSsid.Enabled = -not $Busy
    $txtPassword.Enabled = -not $Busy
    $cmbBand.Enabled = -not $Busy
    if ($Busy) { [System.Windows.Forms.Application]::DoEvents() }
}

function Invoke-UiAction {
    param([scriptblock]$Action)
    if ($script:IsBusy) { return }
    Set-Busy -Busy $true
    try {
        & $Action
    }
    catch {
        Set-Message -Text ('Gagal: ' + $_.Exception.Message) -Kind 'Error'
    }
    finally {
        Set-Busy -Busy $false
        Restore-HotspotFields
        Update-Status
        Update-DeviceList
        Update-QrPreview
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Get-CurrentHotspotConfig {
    try { Get-HotspotConfig } catch { $null }
}

function Sync-HotspotFields {
    $config = Get-CurrentHotspotConfig
    if (-not $config) { return }
    $txtSsid.Text = $config.Ssid
    $txtPassword.Text = $config.Password
    $index = $cmbBand.Items.IndexOf($config.Band)
    if ($index -ge 0) { $cmbBand.SelectedIndex = $index }
}

function Restore-HotspotFields {
    $config = Get-CurrentHotspotConfig
    if ($config) {
        if ([string]::IsNullOrWhiteSpace($txtSsid.Text)) { $txtSsid.Text = $config.Ssid }
        if ([string]::IsNullOrWhiteSpace($txtPassword.Text)) { $txtPassword.Text = $config.Password }
    }
}

$btnStart.Add_Click({
        Invoke-UiAction {
            $config = Get-CurrentHotspotConfig
            $state = Get-HotspotState
            $wantSsid = $txtSsid.Text
            $wantPass = $txtPassword.Text
            $wantBand = [string]$cmbBand.SelectedItem
            Test-HotspotInput -Ssid $wantSsid -Password $wantPass

            $needsConfig = $true
            if ($config -and $config.Ssid -eq $wantSsid -and $config.Password -eq $wantPass -and $config.Band -eq $wantBand) {
                $needsConfig = $false
            }

            if ($state -eq 'On' -and $needsConfig) {
                Set-Message -Text 'Menerapkan pengaturan baru...'
                [void](Apply-HotspotSettings -Ssid $wantSsid -Password $wantPass -Band $wantBand -KeepRunning)
                Set-Message -Text 'Hotspot aktif dengan pengaturan baru.' -Kind 'Success'
                return
            }
            if ($state -eq 'On') {
                Set-Message -Text 'Hotspot sudah aktif.' -Kind 'Success'
                return
            }

            Set-Message -Text 'Mengaktifkan hotspot...'
            Set-HotspotConfig -Ssid $wantSsid -Password $wantPass -Band $wantBand
            $result = Start-Hotspot
            Set-Message -Text ("Hotspot aktif. Perangkat lain bisa konek ke '" + $wantSsid + "'.") -Kind 'Success'
        }
    })

$btnStop.Add_Click({
        Invoke-UiAction {
            Set-Message -Text 'Mematikan hotspot...'
            $result = Stop-Hotspot
            Set-Message -Text 'Hotspot dimatikan.' -Kind 'Success'
        }
    })

$btnApply.Add_Click({
        Invoke-UiAction {
            Set-Message -Text 'Menyimpan pengaturan...'
            $result = Apply-HotspotSettings -Ssid $txtSsid.Text -Password $txtPassword.Text -Band ([string]$cmbBand.SelectedItem) -KeepRunning
            Set-Message -Text $result -Kind 'Success'
        }
    })

$btnRefresh.Add_Click({
        Update-DeviceList
        Update-Status
        Update-QrPreview
    })

$chkShow.Add_CheckedChanged({
        $txtPassword.UseSystemPasswordChar = -not $chkShow.Checked
    })

$txtSsid.Add_TextChanged({ Update-QrPreview })
$txtPassword.Add_TextChanged({ Update-QrPreview })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
        if ($script:IsBusy) { return }
        Update-Status
        Update-DeviceList
    })

$form.Add_Shown({
        Sync-HotspotFields
        Update-Status
        Update-DeviceList
        Update-QrPreview
        $timer.Start()
    })

$form.Add_FormClosing({
        $timer.Stop()
        $timer.Dispose()
    })

[void]$form.ShowDialog()
$form.Dispose()
